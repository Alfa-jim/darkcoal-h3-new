"""
darkcoal-h3-new — RunPod Serverless handler for MiniMax H3 (Ref2VA Q4 Pruned) via ComfyUI
- Supports T2VA (no refs) and Ref2VA (up to 9 images / 3 videos / 3 audios, max 12 assets)
- Uses ComfyUI websocket + /prompt + /history + /view (same proven pattern as darkcoal-qwen-fast)
- Returns gifs/videos/audio/images unified as base64 or S3 (if BUCKET_ENDPOINT_URL set)
"""
import base64, json, os, socket, tempfile, time, traceback, urllib.parse, uuid, logging
import requests, websocket, runpod
from runpod.serverless.utils import rp_upload
from io import BytesIO
# src layout differs between build flatten (ADD src/... ./) and proper src/ dir — handle both + no-src fallback
try:
    from src.network_volume import is_network_volume_debug_enabled, run_network_volume_diagnostics  # type: ignore
except ImportError:
    try:
        from network_volume import is_network_volume_debug_enabled, run_network_volume_diagnostics  # type: ignore
    except ImportError:
        def is_network_volume_debug_enabled(): return False
        def run_network_volume_diagnostics(): return None

logging.basicConfig(level=logging.INFO)
COMFY_HOST = "127.0.0.1:8188"
COMFY_PID_FILE = "/tmp/comfyui.pid"
COMFY_INTERVAL_MS = int(os.environ.get("COMFY_API_AVAILABLE_INTERVAL_MS", "50"))
COMFY_MAX_RETRIES = int(os.environ.get("COMFY_API_AVAILABLE_MAX_RETRIES", "0"))
COMFY_FALLBACK = 500
WS_RECONNECT_ATTEMPTS = int(os.environ.get("WEBSOCKET_RECONNECT_ATTEMPTS", "5"))
WS_RECONNECT_DELAY = int(os.environ.get("WEBSOCKET_RECONNECT_DELAY_S", "3"))
if os.environ.get("WEBSOCKET_TRACE","false").lower()=="true":
    websocket.enableTrace(True)

def _comfy_status():
    try:
        r=requests.get(f"http://{COMFY_HOST}/",timeout=5)
        return {"reachable": r.status_code==200, "status_code": r.status_code}
    except Exception as e:
        return {"reachable": False, "error": str(e)}

def _attempt_ws_reconnect(ws_url, max_attempts, delay_s, initial_error):
    print(f"[h3] ws closed: {initial_error} — reconnecting...")
    last=initial_error
    for attempt in range(max_attempts):
        st=_comfy_status()
        if not st["reachable"]:
            print(f"[h3] ComfyUI HTTP down, abort ws reconnect: {st.get('error')}")
            raise websocket.WebSocketConnectionClosedException("ComfyUI HTTP unreachable")
        print(f"[h3] ws reconnect {attempt+1}/{max_attempts} (HTTP {st.get('status_code')})")
        try:
            ws2=websocket.WebSocket(); ws2.connect(ws_url,timeout=10)
            print("[h3] ws reconnected")
            return ws2
        except (websocket.WebSocketException, ConnectionRefusedError, socket.timeout, OSError) as e:
            last=e; print(f"[h3] reconnect {attempt+1} failed: {e}")
            if attempt < max_attempts-1: time.sleep(delay_s)
    raise websocket.WebSocketConnectionClosedException(f"reconnect failed: {last}")

def validate_input(inp):
    if inp is None: return None, "Please provide input"
    if isinstance(inp,str):
        try: inp=json.loads(inp)
        except: return None, "Invalid JSON"
    wf=inp.get("workflow")
    if wf is None: return None, "Missing 'workflow' parameter"
    images=inp.get("images")
    if images is not None:
        if not isinstance(images,list) or not all("name" in x and "image" in x for x in images):
            return None, "'images' must be list of {name,image}"
    return {"workflow":wf,"images":images,"comfy_org_api_key": inp.get("comfy_org_api_key")}, None

def _get_pid():
    try: return int(open(COMFY_PID_FILE).read().strip())
    except: return None
def _is_alive():
    pid=_get_pid()
    if pid is None: return None
    try: os.kill(pid,0); return True
    except ProcessLookupError: return False
    except PermissionError: return True

def check_server(url, retries=0, delay=50):
    print(f"[h3] Checking ComfyUI at {url}...")
    delay=max(1,delay)
    log_every=max(1,int(10000/delay)); attempt=0
    while True:
        alive=_is_alive()
        if alive is False:
            print("[h3] ComfyUI process exited — not reachable"); return False
        try:
            r=requests.get(url,timeout=5)
            if r.status_code==200:
                print("[h3] ComfyUI reachable"); return True
        except: pass
        attempt+=1
        fallback=retries if retries>0 else COMFY_FALLBACK
        if alive is None and attempt>=fallback:
            print(f"[h3] not reachable after {fallback} tries (no PID file)"); return False
        if attempt % log_every==0:
            print(f"[h3] still waiting {(attempt*delay)/1000:.0f}s attempt {attempt}")
        time.sleep(delay/1000)

def upload_images(images):
    if not images: return {"status":"success","message":"no images","details":[]}
    print(f"[h3] uploading {len(images)} assets...")
    errs=[]; oks=[]
    for im in images:
        try:
            name=im["name"]; uri=im["image"]
            b64=uri.split(",",1)[1] if "," in uri else uri
            blob=base64.b64decode(b64)
            # use image/png for compat; Comfy accepts any
            files={"image":(name, BytesIO(blob), "image/png"), "overwrite":(None,"true")}
            r=requests.post(f"http://{COMFY_HOST}/upload/image",files=files,timeout=30)
            r.raise_for_status()
            oks.append(f"ok {name}"); print(f"[h3] uploaded {name}")
        except Exception as e:
            msg=f"{im.get('name','?')}: {e}"; print(f"[h3] upload err {msg}"); errs.append(msg)
    if errs: return {"status":"error","message":"some uploads failed","details":errs}
    return {"status":"success","message":"all uploaded","details":oks}

def get_available_models():
    try:
        r=requests.get(f"http://{COMFY_HOST}/object_info",timeout=10); r.raise_for_status()
        oi=r.json()
        if "CheckpointLoaderSimple" in oi:
            ckpt=oi["CheckpointLoaderSimple"]["input"]["required"].get("ckpt_name")
            if ckpt: return {"checkpoints": ckpt[0] if isinstance(ckpt[0],list) else []}
    except Exception as e:
        print(f"[h3] get_available_models warn {e}")
    return {}

def queue_workflow(workflow, client_id, comfy_org_api_key=None):
    payload={"prompt":workflow,"client_id":client_id}
    kenv=os.environ.get("COMFY_ORG_API_KEY")
    keff=comfy_org_api_key or kenv
    if keff: payload["extra_data"]={"api_key_comfy_org": keff}
    data=json.dumps(payload).encode()
    r=requests.post(f"http://{COMFY_HOST}/prompt",data=data,headers={"Content-Type":"application/json"},timeout=30)
    if r.status_code==400:
        print(f"[h3] 400 {r.text[:2000]}")
        try:
            err=r.json()
            msg="Workflow validation failed"; details=[]
            if "error" in err:
                ei=err["error"]
                if isinstance(ei,dict): msg=ei.get("message",msg)
                else: msg=str(ei)
            if "node_errors" in err:
                for nid, ne in err["node_errors"].items():
                    if isinstance(ne,dict):
                        for k,v in ne.items(): details.append(f"Node {nid} ({k}): {v}")
                    else: details.append(f"Node {nid}: {ne}")
            if details:
                raise ValueError(msg+":\n"+"\n".join("• "+d for d in details))
            raise ValueError(msg+f" Raw: {r.text[:1200]}")
        except ValueError: raise
        except Exception:
            raise ValueError(f"Validation failed: {r.text[:1500]}")
    r.raise_for_status(); return r.json()

def get_history(pid): 
    r=requests.get(f"http://{COMFY_HOST}/history/{pid}",timeout=30); r.raise_for_status(); return r.json()

def get_file_bytes(filename, subfolder, ftype):
    print(f"[h3] fetch {ftype}/{subfolder}/{filename}")
    qs=urllib.parse.urlencode({"filename":filename,"subfolder":subfolder,"type":ftype})
    try:
        r=requests.get(f"http://{COMFY_HOST}/view?{qs}",timeout=60); r.raise_for_status()
        return r.content
    except Exception as e:
        print(f"[h3] fetch err {e}"); return None

def handler(job):
    if is_network_volume_debug_enabled():
        try: run_network_volume_diagnostics()
        except: pass
    inp=job["input"]; jid=job["id"]
    validated, err = validate_input(inp)
    if err: return {"error": err}
    workflow=validated["workflow"]; input_images=validated.get("images")

    if not check_server(f"http://{COMFY_HOST}/", COMFY_MAX_RETRIES, COMFY_INTERVAL_MS):
        return {"error": f"ComfyUI server ({COMFY_HOST}) not reachable"}

    if input_images:
        up=upload_images(input_images)
        if up["status"]=="error":
            return {"error":"Failed to upload one or more input assets","details": up["details"]}

    ws=None; client_id=str(uuid.uuid4()); prompt_id=None; output_data=[]; errors=[]
    try:
        ws_url=f"ws://{COMFY_HOST}/ws?clientId={client_id}"
        print(f"[h3] ws connect {ws_url}")
        ws=websocket.WebSocket(); ws.connect(ws_url,timeout=10)
        print("[h3] ws connected")
        try:
            qd=queue_workflow(workflow, client_id, comfy_org_api_key=validated.get("comfy_org_api_key"))
            prompt_id=qd.get("prompt_id")
            if not prompt_id: raise ValueError(f"Missing prompt_id in {qd}")
            print(f"[h3] queued {prompt_id}")
        except requests.RequestException as e:
            raise ValueError(f"Error queuing workflow: {e}")

        print(f"[h3] waiting execution {prompt_id}...")
        done=False
        while True:
            try:
                out=ws.recv()
                if isinstance(out,str):
                    m=json.loads(out)
                    if m.get("type")=="status": pass
                    elif m.get("type")=="executing":
                        d=m.get("data",{})
                        if d.get("node") is None and d.get("prompt_id")==prompt_id:
                            print(f"[h3] execution finished {prompt_id}"); done=True; break
                    elif m.get("type")=="execution_error":
                        d=m.get("data",{})
                        if d.get("prompt_id")==prompt_id:
                            ed=f"Node {d.get('node_type')} {d.get('node_id')}: {d.get('exception_message')}"
                            print(f"[h3] execution_error {ed}"); errors.append(f"Workflow execution error: {ed}"); break
            except websocket.WebSocketTimeoutException: continue
            except websocket.WebSocketConnectionClosedException as ce:
                ws=_attempt_ws_reconnect(ws_url, WS_RECONNECT_ATTEMPTS, WS_RECONNECT_DELAY, ce)
                print("[h3] resumed after reconnect"); continue
            except json.JSONDecodeError: continue

        if not done and not errors:
            raise ValueError("Monitoring loop exited without completion")

        print(f"[h3] fetching history {prompt_id}")
        hist=get_history(prompt_id)
        if prompt_id not in hist:
            msg=f"prompt {prompt_id} not in history"
            print(f"[h3] {msg}")
            if not errors: return {"error": msg}
            errors.append(msg); return {"error":"Job processing failed, prompt not in history","details":errors}
        outputs=hist[prompt_id].get("outputs",{})
        if not outputs:
            msg=f"No outputs for {prompt_id}"; print(f"[h3] {msg}")
            if not errors: errors.append(msg)
        print(f"[h3] processing {len(outputs)} nodes")
        MEDIA_KEYS=("images","gifs","videos","audio","audios")
        for nid, nout in outputs.items():
            handled=[k for k in nout.keys() if k in MEDIA_KEYS]
            unhandled=[k for k in nout.keys() if k not in MEDIA_KEYS]
            if unhandled: print(f"[h3] warn node {nid} unhandled {unhandled}")
            for mk in handled:
                items=nout[mk] or []
                print(f"[h3] node {nid} [{mk}] {len(items)} file(s)")
                for info in items:
                    fn=info.get("filename"); sub=info.get("subfolder",""); ftype=info.get("type")
                    if ftype=="temp":
                        print(f"[h3] skip temp {fn}"); continue
                    if not fn:
                        w=f"node {nid} {mk} missing filename {info}"; print(f"[h3] {w}"); errors.append(w); continue
                    b=get_file_bytes(fn,sub,ftype)
                    if not b:
                        e2=f"failed fetch {mk} {fn}"; print(f"[h3] {e2}"); errors.append(e2); continue
                    ext=os.path.splitext(fn)[1] or (".mp4" if mk in ("gifs","videos") else ".png")
                    if os.environ.get("BUCKET_ENDPOINT_URL"):
                        try:
                            with tempfile.NamedTemporaryFile(suffix=ext,delete=False) as tf:
                                tf.write(b); tfp=tf.name
                            print(f"[h3] uploading {fn} to S3...")
                            url=rp_upload.upload_image(jid, tfp)
                            os.remove(tfp); print(f"[h3] S3 {url}")
                            output_data.append({"filename":fn,"type":"s3_url","data":url,"media_type":mk})
                        except Exception as e:
                            e3=f"S3 upload {fn}: {e}"; print(f"[h3] {e3}"); errors.append(e3)
                            try: os.remove(tfp)
                            except: pass
                    else:
                        try:
                            b64=base64.b64encode(b).decode()
                            output_data.append({"filename":fn,"type":"base64","data":b64,"media_type":mk})
                            print(f"[h3] encoded {fn} [{mk}] {len(b)} bytes")
                        except Exception as e:
                            e3=f"b64 {fn}: {e}"; print(f"[h3] {e3}"); errors.append(e3)
    except websocket.WebSocketException as e:
        print(f"[h3] ws err {e}\n{traceback.format_exc()}"); return {"error": f"WebSocket error: {e}"}
    except requests.RequestException as e:
        print(f"[h3] http err {e}\n{traceback.format_exc()}"); return {"error": f"HTTP error: {e}"}
    except ValueError as e:
        print(f"[h3] value err {e}\n{traceback.format_exc()}"); return {"error": str(e)}
    except Exception as e:
        print(f"[h3] unexpected {e}\n{traceback.format_exc()}"); return {"error": f"Unexpected: {e}"}
    finally:
        if ws and getattr(ws,"connected",False):
            try: ws.close()
            except: pass
            print("[h3] ws closed")

    result={}
    if output_data: result["images"]=output_data
    if errors: result["errors"]=errors; print(f"[h3] done with warnings {errors}")
    if not output_data and errors:
        return {"error":"Job processing failed","details":errors}
    if not output_data and not errors:
        print("[h3] success but no outputs"); result["status"]="success_no_images"; result["images"]=[]
    print(f"[h3] done returning {len(output_data)} file(s)")
    return result

if __name__=="__main__":
    print("[h3] starting handler...")
    runpod.serverless.start({"handler":handler})
