"""Install exact LTSC ISO into a disposable KVM guest; retain only QA results/screens."""
import hashlib,http.server,json,os,secrets,socket,subprocess,threading,time,xml.etree.ElementTree as ET
from pathlib import Path
BASE=Path(__file__).resolve().parent
ROOT=Path(os.environ['RUNNER_TEMP'])/'hzs-windows10-vm'
ROOT.mkdir(mode=0o700)
RESULT=Path(os.environ['GITHUB_WORKSPACE'])/'windows10-qa-results'
RESULT.mkdir()
ISO=ROOT/'windows10.iso'
SEED=ROOT/'seed';SEED.mkdir(mode=0o700)
PASSWORD='Hzs!'+secrets.token_hex(14)
NONCE=secrets.token_hex(24)
for value in (PASSWORD,NONCE):print('::add-mask::'+value,flush=True)
events=[]
finished=threading.Event()
class Receiver(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_POST(self):
        if self.path!='/event' or self.headers.get('Authorization')!=NONCE:
            self.send_error(403);return
        size=int(self.headers.get('Content-Length','0'))
        if not 0<size<65536:self.send_error(413);return
        value=json.loads(self.rfile.read(size))
        if set(value)!={'stage','details','at'}:self.send_error(400);return
        events.append(value)
        with (RESULT/'guest-events.ndjson').open('a') as f:f.write(json.dumps(value)+'\n')
        print('GUEST_EVENT '+json.dumps(value),flush=True)
        if value['stage']=='document_ready_for_input':
            assert value['details']['expected_text']=='HazloSimple editado en Windows LTSC'
            info=value['details']
            assert 0<info['click_x']<info['screen_width'] and 0<info['click_y']<info['screen_height']
            monitor('input-send-event',{'events':[
                {'type':'abs','data':{'axis':'x','value':round(info['click_x']*32767/(info['screen_width']-1))}},
                {'type':'abs','data':{'axis':'y','value':round(info['click_y']*32767/(info['screen_height']-1))}}]})
            monitor('input-send-event',{'events':[{'type':'btn','data':{'button':'left','down':True}}]})
            time.sleep(.15)
            monitor('input-send-event',{'events':[{'type':'btn','data':{'button':'left','down':False}}]})
            time.sleep(.2)
            monitor('human-monitor-command',{'command-line':'sendkey ctrl-a'})
            time.sleep(.2)
            for char in value['details']['expected_text']:
                key='spc' if char==' ' else ('shift-'+char.lower() if char.isupper() else char)
                assert key=='spc' or char.isascii() and char.isalpha()
                monitor('human-monitor-command',{'command-line':'sendkey '+key})
                time.sleep(.15)
            monitor('human-monitor-command',{'command-line':'sendkey ctrl-s'})
            time.sleep(1)
            screenshot('notepad-edited-saved')
        self.send_response(200);self.end_headers();self.wfile.write(b'OK')
        if value['stage'] in ('complete','failed'):finished.set()
server=http.server.ThreadingHTTPServer(('127.0.0.1',8765),Receiver)
threading.Thread(target=server.serve_forever,daemon=True).start()
def sha(path):
    value=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(4*1024*1024),b''):value.update(block)
    return value.hexdigest()
def run(args):subprocess.run(args,check=True)
def monitor(command,args=None):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(8);s.connect(str(ROOT/'qmp.sock'))
        f=s.makefile('rwb');json.loads(f.readline())
        def call(cmd,arguments):
            f.write((json.dumps({'execute':cmd,'arguments':arguments or {}})+'\n').encode());f.flush()
            while True:
                answer=json.loads(f.readline())
                if 'return' in answer:return answer['return']
                if 'error' in answer:raise RuntimeError(str(answer['error']))
        call('qmp_capabilities',{})
        return call(command,args)
def screenshot(name):
    destination=RESULT/(name+'.ppm')
    monitor('screendump',{'filename':str(destination)})
    from PIL import Image
    with Image.open(destination) as im:im.save(RESULT/(name+'.png'))
    destination.unlink()
process=None
try:
    assert Path('/dev/kvm').is_char_device()
    access=ROOT/'iso-download.conf'
    user=os.environ['HZS_QA_ISO_USER'];password=os.environ['HZS_QA_ISO_PASSWORD'];url=os.environ['HZS_QA_ISO_URL']
    assert url=='https://nextcloud-159-54-129-141.sslip.io/public.php/webdav'
    access.write_text('url = '+json.dumps(url)+'\nuser = '+json.dumps(user+':'+password)+'\n',encoding='utf-8');access.chmod(0o600)
    print('Downloading exact private ISO via temporary read-only share...',flush=True)
    run(['curl','--fail','--location','--proto','=https','--proto-redir','=https','--connect-timeout','20','--max-time','600','--retry','1','--silent','--show-error','--config',str(access),'--output',str(ISO)])
    access.unlink()
    assert ISO.stat().st_size==4899461120
    assert sha(ISO)=='c90a6df8997bf49e56b9673982f3e80745058723a707aef8f22998ae6479597d'
    print('EXACT_ISO_DOWNLOADED_HASH_VERIFIED',flush=True)
    mas=SEED/'MAS_AIO.cmd'
    run(['curl','--fail','--location','--proto','=https','--proto-redir','=https','--max-time','90','--silent','--show-error','--output',str(mas),'https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/6401d2f36975dc07bcb6d22ea823a8498a75ec01/MAS/All-In-One-Version-KL/MAS_AIO.cmd'])
    assert sha(mas)=='850f979665fb93999acae93f4790c1ff8ed2041532060b7966a121c2d29a0bfa'
    (SEED/'guest.ps1').write_bytes((BASE/'windows10-guest-qa.ps1').read_bytes())
    (SEED/'config.json').write_text(json.dumps({'nonce':NONCE}))
    template=(BASE/'windows10-unattend.xml').read_text().replace('__PASSWORD__',PASSWORD)
    tree=ET.fromstring(template)
    command=tree.find('.//{urn:schemas-microsoft-com:unattend}CommandLine')
    command.text='powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d=(Get-CimInstance Win32_LogicalDisk | Where-Object VolumeName -eq \'HZSQA\' | Select-Object -First 1).DeviceID; & ($d+\'\\guest.ps1\') -Bootstrap"'
    ET.register_namespace('','urn:schemas-microsoft-com:unattend');ET.register_namespace('wcm','http://schemas.microsoft.com/WMIConfig/2002/State')
    ET.ElementTree(tree).write(SEED/'Autounattend.xml',encoding='utf-8',xml_declaration=True)
    run(['genisoimage','-quiet','-J','-r','-V','HZSQA','-o',str(ROOT/'seed.iso'),str(SEED)])
    run(['qemu-img','create','-f','qcow2',str(ROOT/'disk.qcow2'),'40G'])
    log=(ROOT/'qemu.log').open('w')
    args=['sudo','-n','qemu-system-x86_64','-enable-kvm','-cpu','host','-machine','pc','-m','4096','-smp','2',
          '-drive',f'file={ROOT}/disk.qcow2,if=ide,index=0,format=qcow2',
          '-drive',f'file={ISO},if=ide,index=2,media=cdrom,readonly=on',
          '-drive',f'file={ROOT}/seed.iso,if=ide,index=3,media=cdrom,readonly=on',
          '-boot','once=d,order=c','-netdev','user,id=net0','-device','e1000,netdev=net0',
          '-display','none','-vga','std','-usb','-device','usb-tablet','-qmp',f'unix:{ROOT}/qmp.sock,server=on,wait=off',
          '-pidfile',str(ROOT/'qemu.pid'),'-rtc','base=utc']
    process=subprocess.Popen(args,stdout=log,stderr=log)
    start=time.monotonic()
    while not (ROOT/'qmp.sock').exists():
        if process.poll() is not None:raise RuntimeError('QEMU failed to start: '+(ROOT/'qemu.log').read_text())
        if time.monotonic()-start>20:raise TimeoutError('QMP socket unavailable')
        time.sleep(1)
    run(['sudo','chown',f'{os.getuid()}:{os.getgid()}',str(ROOT/'qmp.sock')])
    os.chmod(ROOT/'qmp.sock',0o600)
    for _ in range(3):
        time.sleep(2);monitor('human-monitor-command',{'command-line':'sendkey spc'})
    print('WINDOWS_ISO_VM_BOOT_STARTED',flush=True)
    previous=None
    for minute in range(32):
        if finished.wait(45):break
        if process.poll() is not None:raise RuntimeError('VM stopped before producing result')
        if events:
            stage=events[-1]['stage']
            if stage!=previous:screenshot('stage-'+stage);previous=stage
        else:
            screenshot('installation-latest')
            if minute%2==0:screenshot(f'installation-{minute:02}')
        print(f'VM_PROGRESS seconds={int(time.monotonic()-start)} stage={events[-1]["stage"] if events else "windows_setup"}',flush=True)
    monitor('human-monitor-command',{'command-line':'sendkey shift'})
    time.sleep(3)
    screenshot('final-screen')
    report={'iso_sha256':sha(ISO),'mas_sha256':sha(mas),'vm':{'hypervisor':'QEMU/KVM','memory_mb':4096,'vcpus':2,'disk_gb':40},'events':events,'passed':bool(events and events[-1]['stage']=='complete' and events[-1]['details']['passed']),'entitlement_verified':False}
    (RESULT/'result.json').write_text(json.dumps(report,indent=2))
    if not report['passed']:raise RuntimeError('Windows VM QA incomplete or failed; see events and final screenshot')
    print('WINDOWS10_VM_QA_PASS',flush=True)
finally:
    if process is not None:
        try:monitor('quit')
        except Exception:pass
        try:process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            if (ROOT/'qemu.pid').exists():
                pid=(ROOT/'qemu.pid').read_text().strip();assert pid.isdecimal();subprocess.run(['sudo','kill','-TERM',pid])
    server.shutdown()
    # Disks, setup answers, credentials and licensing state stay outside artifacts.
