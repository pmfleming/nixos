"""Explicit native Pi TUI acceptance; private fixtures, offline, no model calls.

Run with the matching Pi executable on PATH:
    python3 config/pi/tests/worker-dashboard-tui.py
"""
import fcntl, json, os, pathlib, pty, select, signal, struct, subprocess, tempfile, termios, time

extension = pathlib.Path(__file__).resolve().parents[1] / 'worker-dashboard' / 'index.ts'

with tempfile.TemporaryDirectory(prefix='pi-workers-tui-') as tmp:
    root = pathlib.Path(tmp)
    run = root / 'runs' / 'run-1'
    (run / 'control').mkdir(parents=True)
    (run / 'tasks' / 'bt').mkdir(parents=True)
    (run / 'tasks' / 'nm').mkdir(parents=True)
    state = {'run':'run-1','provider':'openai-codex','model':'gpt-6.1-sol','thinking':'high','updated':time.time(),
             'tasks':{'bt':{'title':'Bluetooth fixture','state':'running','started':time.time(),'last_event_at':time.time(),
                            'model_verified':True,'tools':3,'turns':1},
                      'nm':{'title':'Network fixture','state':'queued'}}}
    (run / 'control' / 'state.json').write_text(json.dumps(state))
    progress = run / 'tasks' / 'bt' / 'PROGRESS.md'
    progress.write_text('PRIVATE_PROGRESS_MARKER\nNo effects.\n')
    (run / 'tasks' / 'nm' / 'PROGRESS.md').write_text('SECOND_WORKER_MARKER\nQueued.\n')
    (root / 'home').mkdir()
    master, slave = pty.openpty()
    def resize(rows, cols):
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    resize(32, 100)
    env = {k:os.environ[k] for k in ('PATH', 'LANG') if k in os.environ}
    env.update(HOME=str(root/'home'), TERM='xterm-256color', PI_WORKERS_ROOT=str(root/'runs'),
               PI_CODING_AGENT_DIR=str(root/'agent'), PI_OFFLINE='1', PI_SKIP_VERSION_CHECK='1', PI_TELEMETRY='0')
    command=['pi','--no-extensions','--extension',str(extension),
             '--no-mcp','--no-skills','--no-prompt-templates','--no-context-files','--no-approve','--no-session',
             '--offline','--provider','openai-codex','--model','gpt-6.1-sol','--thinking','high']
    child=subprocess.Popen(command, cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output=bytearray()
    def read_for(seconds):
        until=time.monotonic()+seconds
        while time.monotonic()<until:
            if select.select([master],[],[],0.1)[0]:
                try: data=os.read(master,65536)
                except OSError: break
                if not data: break
                output.extend(data)
                if len(output)>2*1024*1024: raise AssertionError('unbounded terminal output')
        return output.decode('utf8','replace')
    def send(text): os.write(master,text.encode())
    try:
        initial=read_for(3)
        assert '1 running' not in initial and 'Workers:' not in initial, initial[-5000:]
        assert 'Alt+1' not in initial and 'Alt+W reports' not in initial, initial[-5000:]
        assert '1 - Running' in initial and '2 - Queued' in initial and '╭' in initial, initial[-5000:]
        # Opening a worker must not consume or submit the orchestrator's draft.
        send('ORCHESTRATOR_DRAFT'); read_for(0.3)
        start=len(output); send('\x1b1'); read_for(1)
        direct=output[start:].decode('utf8','replace')
        assert 'JSON process cannot be attached' in direct, direct[-5000:]
        assert 'PRIVATE_PROGRESS_MARKER' not in direct, direct[-5000:]
        start=len(output); send('\x1b2'); read_for(1)
        switched=output[start:].decode('utf8','replace')
        assert 'not finished' in switched, switched[-5000:]
        start=len(output); send('\x1b0'); read_for(0.5)
        send('_PRESERVED'); read_for(0.3) # force the untouched editor line to repaint
        returned=output[start:].decode('utf8','replace')
        assert 'ORCHESTRATOR_DRAFT_PRESERVED' in returned, returned[-5000:]
        send('\x15') # clear the preserved, unsent draft
        start=len(output); send('\x1bw'); read_for(0.5)
        assert 'running · bt' in output[start:].decode('utf8','replace')
        send('\x1bw'); read_for(0.5) # same shortcut returns to orchestrator
        send('/workers ers\r')
        invalid=read_for(1)
        assert 'Unknown or unavailable worker run "ers"' in invalid, invalid[-5000:]
        assert 'Workers unavailable' not in invalid, invalid[-5000:]
        send('/workers\r')
        opened=read_for(2)
        assert 'running · bt' in opened, opened[-5000:]
        send('\r')
        shown=read_for(2)
        assert 'PRIVATE_PROGRESS_MARKER' in shown, shown[-5000:]
        progress.write_text('PRIVATE_PROGRESS_SECOND\nStill read-only.\n')
        updated=read_for(3)
        assert 'PRIVATE_PROGRESS_SECOND' in updated, updated[-5000:]
        state['tasks']['bt']['state']='review-required'
        state['tasks']['nm']['state']='cancelled-before-launch'
        state['tasks']['bt']['reported_status']='partial'
        state['tasks']['bt']['phase']='quality'
        state['tasks']['bt']['ended']=time.time()
        state['updated']=time.time()
        (run/'control'/'dashboard.json').write_text(json.dumps(state))
        terminal=read_for(3)
        assert 'quality · review-required (partial)' in terminal, terminal[-5000:]
        resize(10,24); os.kill(child.pid,signal.SIGWINCH); read_for(1)
        resize(32,100); os.kill(child.pid,signal.SIGWINCH); read_for(1)
        send('\x1b'); read_for(0.3); send('\x1b'); main=read_for(0.5)
        assert 'handoff ready for review' in main, main[-5000:]
        send('/workers hide\r'); read_for(0.5)
        send('/workers show\r'); final=read_for(0.5)
        send('/reload\r'); read_for(2)
        send('/workers\r'); final=read_for(2)
        assert child.poll() is None, final[-5000:]
        assert 'Failed to load extension' not in final and 'TypeError:' not in final and 'ReferenceError:' not in final, final[-5000:]
        assert 'review-required · bt' in final, final[-5000:]
        send('\x1b0'); read_for(0.5)
        start=len(output); send('/workers\r'); read_for(0.5); send('\r'); read_for(1)
        reloaded=output[start:].decode('utf8','replace')
        assert 'Worker 1 · bt' in reloaded and 'PRIVATE_PROGRESS_SECOND' in reloaded, reloaded[-5000:]
        send('\x1b0'); read_for(0.3)
        assert child.poll() is None
        print('PASS: real Pi TUI numbered bottom box, live legacy worker attachment refusal, draft-preserving return, list toggle, invalid-run rejection, live report refresh, review notification, resize, hide/show and reload')
    finally:
        if child.poll() is None: os.killpg(child.pid,signal.SIGTERM)
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL); child.wait()
        os.close(master)
