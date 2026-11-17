// Browser-only regression checks. The preparation script embeds the production
// DSP source verbatim, so these checks require no packages or toolchain.
(async () => {
const results = [];
function check(name, pass) { results.push({name, pass: !!pass}); }
function near(actual, expected, tolerance) { return Math.abs(actual - expected) <= tolerance; }
try {
 const rate = 48000, n = 4096;
 const silence = new Float32Array(n);
 const silent = DSP.stats(silence, rate);
 check('Silence: zero RMS, peak and clipping', silent.rms === 0 && silent.peak === 0 && silent.clipped === 0);
 check('Silence: negative infinite dBFS', DSP.db(silent.rms) === -Infinity);
 const tone = Float32Array.from({length:n}, (_, i) => .5*Math.sin(2*Math.PI*40*i/n));
 const stats = DSP.stats(tone, rate), spectrum = DSP.fftPower(tone, 0, n);
 check('Half-amplitude sine: -6.0206 dBFS peak', near(DSP.db(stats.peak), -6.0206, .0001));
 check('Half-amplitude sine: -9.0309 dBFS RMS', near(DSP.db(stats.rms), -9.0309, .0001));
 check('Hann spectrum: calibrated -6.0206 dBFS tone', near(10*Math.log10(spectrum[40]), -6.0206, .001));
 check('FFT tone lands at bin 40', spectrum.indexOf(Math.max(...spectrum)) === 40);
 check('Sine has negligible DC', Math.abs(stats.dc) < 1e-8);
 const clipped = DSP.stats(Float32Array.of(-1, 1, 0, .5), rate);
 check('Clipping counts both polarities', clipped.clipped === 2 && clipped.clipPercent === 50);
 const offset = DSP.stats(Float32Array.of(.25, .25, .25, .25), rate);
 check('DC offset is signed arithmetic mean', offset.dc === .25);
 const region = DSP.stats(Float32Array.of(1, .5, .5, 1), rate, 1, 3);
 check('Selection excludes outside peaks', region.peak === .5 && region.samples === 2);
 const wave = new DataView(DSP.wav([Float32Array.of(-1, 0, 1), Float32Array.of(1, 0, -1)], rate));
 check('WAV header: PCM stereo with correct size and rate', wave.byteLength === 56 && wave.getUint16(22,true) === 2 && wave.getUint32(24,true) === rate && wave.getUint32(40,true) === 12);
 check('WAV: correct channel interleave and integer bounds', wave.getInt16(44,true) === -32768 && wave.getInt16(46,true) === 32767 && wave.getInt16(52,true) === 32767 && wave.getInt16(54,true) === -32768);
 const reference = DSP.demo(), quiet = DSP.stats(reference.channels[0], rate, 0, rate), active = DSP.stats(reference.channels[0], rate, rate*2, rate*3);
 check('Synthetic reference is 8 seconds', reference.channels[0].length === rate*8);
 check('Quiet reference is about -52.7 dBFS', near(DSP.db(quiet.rms), -52.73, .15));
 check('Reference signal has >35 dB contrast', DSP.db(active.rms) - DSP.db(quiet.rms) > 35);
 const shortFFT = DSP.fftPower(tone, 0, 16384, 960);
 check('Short zero-padded selection stays finite', [...shortFFT].every(Number.isFinite));
 // Regression for blob:null worklet rejection on local file origins.
 let moduleLoads=0,completed=0,captureErrors=0,processor;
 const chunks=[];
 const context={audioWorklet:{async addModule(){moduleLoads++;throw Error('Simulated module load failure');}},createScriptProcessor(size,inputs,outputs){processor={size,inputs,outputs,disconnect(){this.disconnected=true;}};return processor;}};
 const pcm=await createPCMCapture(context,{protocol:'file:',limit:6,channels:2,onData:parts=>chunks.push(parts),onDone:()=>completed++,onError:()=>captureErrors++});
 check('Local files skip module loading entirely', moduleLoads===0&&pcm.backend==='inline-pcm');
 check('PCM capture keeps two input channels and a silent output', processor.inputs===2&&processor.outputs===1&&processor.size===4096);
 const left=Float32Array.of(.1,.2,.3,.4),right=Float32Array.of(-.1,-.2,-.3,-.4),output=new Float32Array(4).fill(1);
 const event={inputBuffer:{length:4,numberOfChannels:2,getChannelData:ch=>[left,right][ch]},outputBuffer:{numberOfChannels:1,getChannelData:()=>output}};
 const callback=processor.onaudioprocess;
 callback(event);
 check('Input channels are copied independently', chunks[0][0][1]===left[1]&&chunks[0][1][1]===right[1]);
 left[1]=.99;
 check('Browser buffer reuse cannot change captured PCM', near(chunks[0][0][1],.2,1e-6));
 check('Capture never emits microphone audio to speakers', output.every(v=>v===0));
 callback(event);
 check('Automatic limit trims the final buffer exactly', chunks.length===2&&chunks[1][0].length===2&&completed===1);
 pcm.stop();callback(event);
 check('Stop and late callbacks cannot duplicate a completed capture', completed===1&&chunks.length===2&&captureErrors===0);
 pcm.dispose();
 check('Disposal removes audio callbacks and disconnects', processor.onaudioprocess===null&&processor.disconnected);
 let stopped=0,manualChunks=0;
 const manual=await createPCMCapture(context,{protocol:'file:',limit:100,channels:1,onData:()=>manualChunks++,onDone:()=>stopped++,onError:()=>captureErrors++});
 processor.onaudioprocess(event);manual.stop();manual.stop();
 check('Manual stop finishes once and preserves mono buffers', stopped===1&&manualChunks===1&&processor.inputs===1);
 manual.dispose();
 const originalWorklet=globalThis.AudioWorkletNode;
 globalThis.AudioWorkletNode=class {};
 try {
  const fallback=await createPCMCapture(context,{protocol:'https:',limit:100,channels:1,onData(){},onDone(){},onError(){}});
  check('Rejected worklet load falls back to inline PCM',moduleLoads===1&&fallback.backend==='inline-pcm'&&fallback.fallbackReason.includes('Simulated'));
  fallback.dispose();
 } finally {globalThis.AudioWorkletNode=originalWorklet;}
 let unsupported=false;
 try {await createPCMCapture({}, {protocol:'file:',limit:100,channels:1});} catch(error) {unsupported=error.message.includes('cannot capture PCM');}
 check('Unsupported browsers report an actionable capture error',unsupported);
} catch (error) { results.push({name: error.stack || String(error), pass:false}); }
document.getElementById('result').textContent = `${results.filter(r=>r.pass).length}/${results.length} checks passed`;
document.getElementById('result').style.color = results.every(r=>r.pass) ? '#61dcc4' : '#ff8188';
const list = document.getElementById('checks');
for (const r of results) { const item=document.createElement('li');item.textContent=`${r.pass?'PASS':'FAIL'} · ${r.name}`;list.append(item); }
})();
