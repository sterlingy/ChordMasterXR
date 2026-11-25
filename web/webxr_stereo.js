// Two-pass WebXR stereo for browsers without the OVR_multiview2 WebGL extension,
// such as Chrome on Galaxy XR.
// Copied from the Shivoo XR plugin (web/webxr_stereo.js); the only ChordMasterXR
// change is select/squeeze reporting (marked "ChordMasterXR").
// (Three.js r186): require the "local" space, keep the headset frame loop alive
// from the first callback, and never present to the page canvas during VR.
// Godot still draws both eyes side by side. That image is copied into the
// XRWebGLLayer views. Touching the canvas from inside an immersive frame does
// not return on a real headset, which is the "page isn't responding" stall.
(function () {
	if (window.ShivooStereo) {
		return;
	}

	const MULTIVIEW_EXTENSIONS = ['OVR_multiview2', 'OVR_multiview', 'OCULUS_multiview'];

	const originalRequestAnimationFrame = window.requestAnimationFrame.bind(window);
	const requests = new Map();
	let nextRequestId = 1;
	let installed = false;
	let presenting = false;
	let submitted = false;
	let sessionPending = false;
	const liveSessions = new Set();

	let gl = null;
	let origBind = null;
	let origBlit = null;
	let origGetParameter = null;
	let origDrawArrays = null;
	let origEnable = null;
	let origDisable = null;
	let layer = null;
	let readFramebuffer = null;
	let scissor = false;
	let quad = null;
	let colorTex = null;
	let colorFbo = null;
	let colorW = 0;
	let colorH = 0;
	let boundTex2D = null;
	let blendEnabled = false;
	let depthEnabled = false;
	const texInfo = new Map();
	const fboInfo = new Map();
	let eyeFramebuffers = [];
	let referenceSpace = null;
	let viewports = [];
	let lastCallback = null;
	let drawFramebuffer = null;
	let offscreenFramebuffer = null;

	const stereo = {
		session: null,
		referenceSpaceType: '',
		frameJson: '',
		// pending | yes | no | timeout.
		vrSupported: 'pending',
		arSupported: 'pending',
		// immersive-vr or immersive-ar while a session runs.
		sessionMode: '',
		stage: 'idle',
	};

	function stage(name) {
		stereo.stage = name;
		console.info('WebXR stereo:', name);
	}

	function getCanvas() {
		return document.getElementById('canvas') || document.querySelector('canvas');
	}

	function hasMultiview() {
		const canvas = getCanvas();
		const context = canvas ? canvas.getContext('webgl2') : null;
		if (!context) {
			return false;
		}
		const supported = context.getSupportedExtensions() || [];
		return MULTIVIEW_EXTENSIONS.some((name) => supported.includes(name));
	}

	function matrix(transform) {
		return transform ? Array.from(transform.matrix) : null;
	}

	function capture(frame) {
		const data = { head: null, views: [], inputs: [] };
		viewports = [];
		const pose = frame.getViewerPose(referenceSpace);
		if (pose) {
			data.head = matrix(pose.transform);
			for (const view of pose.views) {
				const viewport = layer.getViewport(view);
				const box = [viewport.x, viewport.y, viewport.width, viewport.height];
				viewports.push(box);
				data.views.push({
					transform: matrix(view.transform),
					projection: Array.from(view.projectionMatrix),
					viewport: box,
				});
			}
		}
		for (const source of stereo.session.inputSources) {
			if (source.handedness !== 'left' && source.handedness !== 'right') {
				continue;
			}
			const aim = frame.getPose(source.targetRaySpace, referenceSpace);
			const grip = source.gripSpace ? frame.getPose(source.gripSpace, referenceSpace) : null;
			const gamepad = source.gamepad;
			const joints = source.hand ? handJoints(frame, source.hand) : null;
			const gesture = joints ? handGesture(joints) : null;
			data.inputs.push({
				hand: source.handedness,
				profile: source.profiles.length > 0 ? source.profiles[0] : '',
				aim: aim ? matrix(aim.transform) : null,
				grip: grip ? matrix(grip.transform) : null,
				standard: gamepad ? gamepad.mapping === 'xr-standard' : false,
				buttons: gamepad ? gamepad.buttons.map((button) => button.value) : [],
				axes: gamepad ? Array.from(gamepad.axes) : [],
				joints: joints,
				// Hands have no gamepad, so the gesture replaces its grip and trigger.
				isHand: !!source.hand,
				grasp: gesture ? gesture.grasp : 0,
				pinch: gesture ? gesture.pinch : 0,
				// ChordMasterXR: the browser's own select/squeeze (the system
				// pinch), for runtimes whose joints don't give a clean pinch.
				select: readGesture(source, 'select'),
				squeeze: readGesture(source, 'squeeze'),
			});
		}
		stereo.frameJson = JSON.stringify(data);
	}

	// ChordMasterXR: select/squeeze state per input source, from the session's
	// events. A press is latched until one frame has reported it, so a quick
	// pinch that starts and ends between two frames still counts.
	const gestures = new WeakMap();

	function gestureState(source) {
		let state = gestures.get(source);
		if (!state) {
			// held: between start and end; latched: pressed since the last frame read it.
			state = { select: { held: false, latched: false }, squeeze: { held: false, latched: false } };
			gestures.set(source, state);
		}
		return state;
	}

	function watchGestures(session) {
		for (const kind of ['select', 'squeeze']) {
			session.addEventListener(kind + 'start', (event) => {
				const g = gestureState(event.inputSource)[kind];
				g.held = true;
				g.latched = true;
			});
			session.addEventListener(kind + 'end', (event) => {
				gestureState(event.inputSource)[kind].held = false;
			});
		}
	}

	function readGesture(source, kind) {
		const g = gestureState(source)[kind];
		const down = g.held || g.latched;
		g.latched = false;
		return down;
	}

	const jointSpaces = new WeakMap();
	const jointPoses = new Float32Array(25 * 16);
	const roundJoint = (value) => Math.round(value * 1e5) / 1e5;

	// The 25 WebXR hand joints, in XRHand order (wrist first), as 16-float matrices.
	function handJoints(frame, hand) {
		if (!frame.fillPoses) {
			return null;
		}
		let spaces = jointSpaces.get(hand);
		if (!spaces) {
			spaces = Array.from(hand.values());
			jointSpaces.set(hand, spaces);
		}
		if (spaces.length !== 25 || !frame.fillPoses(spaces, referenceSpace, jointPoses)) {
			return null;
		}
		return Array.from(jointPoses, roundJoint);
	}

	// Hands report only joints, so the values Godot's OpenXR hand interaction
	// profile reads from the runtime are derived from the skeleton instead: how
	// far the fingers are curled (grasp, bound to grip) and how close the thumb
	// tip is to the index tip (pinch, bound to trigger). A closed hand reads 1.
	function handGesture(joints) {
		const at = (joint, axis) => joints[joint * 16 + 12 + axis];
		const delta = (a, b, axis) => at(a, axis) - at(b, axis);
		const length = (a, b) => Math.hypot(delta(a, b, 0), delta(a, b, 1), delta(a, b, 2));
		// Bend at b between the segments a->b and b->c, in radians.
		const bend = (a, b, c) => {
			const u = [delta(b, a, 0), delta(b, a, 1), delta(b, a, 2)];
			const v = [delta(c, b, 0), delta(c, b, 1), delta(c, b, 2)];
			const ul = Math.hypot(u[0], u[1], u[2]);
			const vl = Math.hypot(v[0], v[1], v[2]);
			if (ul === 0 || vl === 0) {
				return 0;
			}
			const dot = (u[0] * v[0] + u[1] * v[1] + u[2] * v[2]) / (ul * vl);
			return Math.acos(Math.max(-1, Math.min(1, dot)));
		};
		// Index, middle, ring and pinky: proximal, intermediate, distal, tip.
		const fingers = [[6, 7, 8, 9], [11, 12, 13, 14], [16, 17, 18, 19], [21, 22, 23, 24]];
		let curled = 0;
		for (const [proximal, intermediate, distal, tip] of fingers) {
			curled += bend(proximal, intermediate, distal) + bend(intermediate, distal, tip);
		}
		// A fist bends each finger about 180 degrees, so this reads 0 to 1.
		curled = curled / (4 * Math.PI);
		const pinch = length(4, 9);
		return {
			// Reaching XR Tools' 0.8 grab threshold takes a natural closing of the hand.
			grasp: Math.min(1, Math.max(0, curled / 0.7)),
			pinch: Math.min(1, Math.max(0, (0.08 - pinch) / 0.06)),
		};
	}

	function xrBusy() {
		return sessionPending || liveSessions.size > 0;
	}

	function rememberFramebuffer(framebuffer) {
		if (framebuffer && (!layer || framebuffer !== layer.framebuffer)) {
			offscreenFramebuffer = framebuffer;
		}
	}

	function watchSession(session) {
		liveSessions.add(session);
		session.addEventListener('end', () => {
			liveSessions.delete(session);
			if (liveSessions.size === 0) {
				sessionPending = false;
				clearMirrorLayout();
				unlockHeadsetCanvas();
			}
		});
	}

	function ensureQuad() {
		if (quad) {
			return;
		}
		function compile(type, source) {
			const shader = gl.createShader(type);
			gl.shaderSource(shader, source);
			gl.compileShader(shader);
			return shader;
		}
		const program = gl.createProgram();
		gl.attachShader(program, compile(gl.VERTEX_SHADER, '#version 300 es\nlayout(location=0) in vec2 p;out vec2 uv;void main(){uv=vec2(p.x*0.5+0.5,p.y*0.5+0.5);gl_Position=vec4(p,0.0,1.0);}'));
		gl.attachShader(program, compile(gl.FRAGMENT_SHADER, '#version 300 es\nprecision mediump float;uniform sampler2D tex;uniform vec4 rect;in vec2 uv;out vec4 c;void main(){c=texture(tex,mix(rect.xy,rect.zw,uv));}'));
		gl.linkProgram(program);
		const buffer = gl.createBuffer();
		gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
		gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
		quad = { program: program, buffer: buffer, rect: gl.getUniformLocation(program, 'rect'), tex: gl.getUniformLocation(program, 'tex') };
	}

	// Draw Godot's image into the headset layer. Blitting into that layer, or
	// into the page canvas, stalls SteamVR's Chrome until it reports the page
	// as not responding. A textured draw is what Three.js does.
	function copyEyes(srcX0, srcY0, srcX1, srcY1, source) {
		if (!layer || !source || viewports.length === 0) {
			return false;
		}
		const width = srcX1 - srcX0;
		const height = srcY1 - srcY0;
		if (width <= 0 || height <= 0) {
			return false;
		}
		if (!colorTex || colorW !== width || colorH !== height) {
			colorTex = gl.createTexture();
			gl.bindTexture(gl.TEXTURE_2D, colorTex);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
			gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
			colorFbo = gl.createFramebuffer();
			origBind(gl.FRAMEBUFFER, colorFbo);
			drawFramebuffer = colorFbo;
			gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, colorTex, 0);
			colorW = width;
			colorH = height;
		}
		origBind(gl.READ_FRAMEBUFFER, source);
		readFramebuffer = source;
		origBind(gl.DRAW_FRAMEBUFFER, colorFbo);
		drawFramebuffer = colorFbo;
		origBlit(srcX0, srcY0, srcX1, srcY1, 0, 0, width, height, gl.COLOR_BUFFER_BIT, gl.NEAREST);
		ensureQuad();
		origBind(gl.FRAMEBUFFER, layer.framebuffer);
		drawFramebuffer = layer.framebuffer;
		gl.useProgram(quad.program);
		gl.bindBuffer(gl.ARRAY_BUFFER, quad.buffer);
		gl.enableVertexAttribArray(0);
		gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
		gl.disable(gl.SCISSOR_TEST);
		gl.disable(gl.DEPTH_TEST);
		gl.disable(gl.BLEND);
		gl.activeTexture(gl.TEXTURE0);
		gl.bindTexture(gl.TEXTURE_2D, colorTex);
		gl.uniform1i(quad.tex, 0);
		const count = viewports.length;
		for (let i = 0; i < count; i++) {
			const box = viewports[i];
			gl.viewport(box[0], box[1], box[2], box[3]);
			gl.uniform4f(quad.rect, i / count, 0, (i + 1) / count, 1);
			origDrawArrays(gl.TRIANGLE_STRIP, 0, 4);
		}
		origBind(gl.FRAMEBUFFER, null);
		drawFramebuffer = null;
		submitted = true;
		return true;
	}

	let canvasLock = null;

	// Godot sizes the page from the window. Hold that at the headset buffer for
	// the whole session so each eye is copied 1:1, and the bitmap is allocated once.
	function lockHeadsetCanvas() {
		if (canvasLock || viewports.length === 0) {
			return;
		}
		const scale = window.devicePixelRatio || 1;
		let width = 0;
		let height = 0;
		for (const box of viewports) {
			width += box[2];
			height = Math.max(height, box[3]);
		}
		const eyeScale = parseFloat(stereo.param('eyescale')) || 1;
		const cssW = (width * eyeScale) / scale;
		const cssH = (height * eyeScale) / scale;
		const ownW = Object.getOwnPropertyDescriptor(window, 'innerWidth');
		const ownH = Object.getOwnPropertyDescriptor(window, 'innerHeight');
		try {
			Object.defineProperty(window, 'innerWidth', { configurable: true, get: () => cssW });
			Object.defineProperty(window, 'innerHeight', { configurable: true, get: () => cssH });
		} catch (error) {
			return;
		}
		canvasLock = { ownW: ownW, ownH: ownH };
	}

	function unlockHeadsetCanvas() {
		if (!canvasLock) {
			return;
		}
		const ownW = canvasLock.ownW;
		const ownH = canvasLock.ownH;
		canvasLock = null;
		if (ownW) {
			Object.defineProperty(window, 'innerWidth', ownW);
		} else {
			delete window.innerWidth;
		}
		if (ownH) {
			Object.defineProperty(window, 'innerHeight', ownH);
		} else {
			delete window.innerHeight;
		}
	}

	function clearMirrorLayout() {
		if (!gl || !gl.canvas) {
			return;
		}
		const canvas = gl.canvas;
		canvas.style.transform = '';
		canvas.style.transformOrigin = '';
		canvas.style.clipPath = '';
		canvas.style.top = '';
		document.documentElement.style.overflow = '';
		document.body.style.overflow = '';
	}

	function noteEyeFramebuffer() {
		if (!presenting || !drawFramebuffer) {
			return;
		}
		const info = fboInfo.get(drawFramebuffer);
		if (!info) {
			return;
		}
		const matches = viewports.some((box) => box[2] === info.w && box[3] === info.h);
		if (!matches) {
			return;
		}
		const existing = eyeFramebuffers.indexOf(drawFramebuffer);
		if (existing !== -1) {
			eyeFramebuffers.splice(existing, 1);
		}
		eyeFramebuffers.push(drawFramebuffer);
	}

	function rememberTexSize(texture, width, height) {
		if (texture && width > 0 && height > 0) {
			texInfo.set(texture, { w: width, h: height });
		}
	}

	function rememberFboTexture(texture) {
		if (!drawFramebuffer || !texture) {
			return;
		}
		const size = texInfo.get(texture);
		if (!size) {
			return;
		}
		fboInfo.set(drawFramebuffer, { tex: texture, w: size.w, h: size.h });
		noteEyeFramebuffer();
	}

	// Draw with blending off, then put GL back. Leaving blend off makes the next
	// Godot frame composite darker, which reads as a fast brightness flicker.
	function withReplaceDraw(draw) {
		const blend = blendEnabled;
		const depth = depthEnabled;
		const scissorWas = scissor;
		if (blend) {
			origDisable(gl.BLEND);
		}
		if (depth) {
			origDisable(gl.DEPTH_TEST);
		}
		if (scissorWas) {
			origDisable(gl.SCISSOR_TEST);
		}
		draw();
		if (blend) {
			origEnable(gl.BLEND);
			blendEnabled = true;
		}
		if (depth) {
			origEnable(gl.DEPTH_TEST);
			depthEnabled = true;
		}
		if (scissorWas) {
			origEnable(gl.SCISSOR_TEST);
			scissor = true;
		}
	}

	function drawTexture(texture, x, y, w, h) {
		gl.viewport(x, y, w, h);
		gl.bindTexture(gl.TEXTURE_2D, texture);
		boundTex2D = texture;
		// Godot stores viewport textures upside down. Flip V or looking around feels reversed.
		gl.uniform4f(quad.rect, 0, 1, 1, 0);
		origDrawArrays(gl.TRIANGLE_STRIP, 0, 4);
	}

	// Copies the two eye textures already rendered this frame into the headset.
	// The browser window is left alone.
	function presentEyes() {
		if (eyeFramebuffers.length < viewports.length) {
			return false;
		}
		const eyes = eyeFramebuffers.slice(-viewports.length);
		ensureQuad();
		withReplaceDraw(() => {
			origBind(gl.FRAMEBUFFER, layer.framebuffer);
			drawFramebuffer = layer.framebuffer;
			gl.useProgram(quad.program);
			gl.bindBuffer(gl.ARRAY_BUFFER, quad.buffer);
			gl.enableVertexAttribArray(0);
			gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
			gl.activeTexture(gl.TEXTURE0);
			gl.uniform1i(quad.tex, 0);
			for (let i = 0; i < viewports.length; i++) {
				const info = fboInfo.get(eyes[i]);
				const box = viewports[i];
				drawTexture(info.tex, box[0], box[1], box[2], box[3]);
			}
		});
		submitted = true;
		return true;
	}

	function paintLayer() {
		if (!layer || !origBind) {
			return;
		}
		origBind(gl.FRAMEBUFFER, layer.framebuffer);
		drawFramebuffer = layer.framebuffer;
		gl.disable(gl.SCISSOR_TEST);
		gl.viewport(0, 0, layer.framebufferWidth, layer.framebufferHeight);
		gl.clearColor(0, 0, 0, stereo.sessionMode === 'immersive-ar' ? 0 : 1);
		gl.clear(gl.COLOR_BUFFER_BIT);
		origBind(gl.FRAMEBUFFER, null);
		drawFramebuffer = null;
		submitted = true;
	}

	function finishFrame() {
		if (submitted) {
			return;
		}
		const canvas = gl.canvas;
		if (!copyEyes(0, 0, canvas.width, canvas.height, offscreenFramebuffer)) {
			paintLayer();
		}
	}

	// Godot presents by blitting, or drawing a quad, onto the canvas. Both wait
	// forever inside an immersive frame. Send the offscreen image to the layer
	// and drop anything aimed at the canvas.
	function hookContext(context) {
		if (!context || context.blitFramebuffer.__shivoo) {
			return;
		}
		origBind = context.bindFramebuffer.bind(context);
		origBlit = context.blitFramebuffer.bind(context);
		origGetParameter = context.getParameter.bind(context);
		origDrawArrays = context.drawArrays.bind(context);
		origEnable = context.enable.bind(context);
		origDisable = context.disable.bind(context);
		const origDrawElements = context.drawElements.bind(context);
		const origClear = context.clear.bind(context);
		try {
			drawFramebuffer = origGetParameter(context.DRAW_FRAMEBUFFER_BINDING);
			readFramebuffer = origGetParameter(context.READ_FRAMEBUFFER_BINDING);
			scissor = !!origGetParameter(context.SCISSOR_TEST);
		} catch (error) {
			// The context can answer these once rendering has started.
		}
		context.getParameter = function (pname) {
			// Godot's canvas present queries these and then blits. The query itself
			// flushes the GPU, and during SteamVR that flush never returns.
			if (xrBusy()) {
				if (pname === context.DRAW_FRAMEBUFFER_BINDING || pname === context.FRAMEBUFFER_BINDING) {
					return drawFramebuffer;
				}
				if (pname === context.READ_FRAMEBUFFER_BINDING) {
					return readFramebuffer;
				}
				if (pname === context.SCISSOR_TEST) {
					return scissor;
				}
			}
			return origGetParameter(pname);
		};
		context.enable = function (cap) {
			if (cap === context.SCISSOR_TEST) {
				scissor = true;
			} else if (cap === context.BLEND) {
				blendEnabled = true;
			} else if (cap === context.DEPTH_TEST) {
				depthEnabled = true;
			}
			return origEnable(cap);
		};
		context.disable = function (cap) {
			if (cap === context.SCISSOR_TEST) {
				scissor = false;
			} else if (cap === context.BLEND) {
				blendEnabled = false;
			} else if (cap === context.DEPTH_TEST) {
				depthEnabled = false;
			}
			return origDisable(cap);
		};
		context.bindFramebuffer = function (target, framebuffer) {
			if (target === context.FRAMEBUFFER) {
				drawFramebuffer = framebuffer;
				readFramebuffer = framebuffer;
			} else if (target === context.DRAW_FRAMEBUFFER) {
				drawFramebuffer = framebuffer;
			} else if (target === context.READ_FRAMEBUFFER) {
				readFramebuffer = framebuffer;
			}
			rememberFramebuffer(framebuffer);
			return origBind(target, framebuffer);
		};
		context.blitFramebuffer = function (srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter) {
			const toCanvas = drawFramebuffer === null && (mask & context.COLOR_BUFFER_BIT);
			if (xrBusy() && toCanvas) {
				return;
			}
			return origBlit(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
		};
		context.drawArrays = function () {
			if (xrBusy() && drawFramebuffer === null) {
				return;
			}
			return origDrawArrays.apply(context, arguments);
		};
		context.drawElements = function () {
			if (xrBusy() && drawFramebuffer === null) {
				return;
			}
			return origDrawElements.apply(context, arguments);
		};
		context.clear = function (mask) {
			if (xrBusy() && drawFramebuffer === null) {
				return;
			}
			return origClear(mask);
		};
		context.blitFramebuffer.__shivoo = true;
	}

	// Once a second the console gets one line: XR frame rate, the gap between XR
	// frames, time inside Godot's frame, time copying into the headset, and how
	// often Godot ran outside an XR frame. stereo.godotInfo is filled by GDScript.
	const stats = {
		since: 0, frames: 0, last: 0,
		gap: 0, gapMax: 0, godot: 0, godotMax: 0, copy: 0, copyMax: 0,
		outside: 0, gaps: [],
	};
	const COMMON_RATES = [60, 72, 80, 90, 100, 120, 144];

	// The headset's refresh rate. Chrome on SteamVR has no session.frameRate, so
	// it comes from the median gap between XR frames; dropped frames don't skew it.
	function measureFrameRate() {
		const session = stereo.session;
		if (session && typeof session.frameRate === 'number' && session.frameRate > 0) {
			return session.frameRate;
		}
		if (stats.gaps.length < 30) {
			return 0;
		}
		const sorted = stats.gaps.slice().sort((a, b) => a - b);
		const rate = 1000 / sorted[sorted.length >> 1];
		return COMMON_RATES.reduce((best, value) => (Math.abs(value - rate) < Math.abs(best - rate) ? value : best));
	}

	function report(now) {
		if (!stats.since) {
			stats.since = now;
			return;
		}
		if (now - stats.since < 1000 || stats.frames === 0) {
			return;
		}
		const n = stats.frames;
		const seconds = (now - stats.since) / 1000;
		const f = (value) => value.toFixed(1);
		const rate = measureFrameRate();
		if (rate > 0) {
			stereo.frameRate = rate;
		}
		stats.gaps.length = 0;
		console.info(
			`WebXR stereo: ${f(n / seconds)} fps (headset ${stereo.frameRate} Hz) | gap ${f(stats.gap / n)} max ${f(stats.gapMax)} ms`
			+ ` | godot ${f(stats.godot / n)} max ${f(stats.godotMax)} ms`
			+ ` | copy ${f(stats.copy / n)} max ${f(stats.copyMax)} ms`
			+ ` | outside-XR runs ${stats.outside} | ${stereo.godotInfo}`,
		);
		Object.assign(stats, { since: now, frames: 0, gap: 0, gapMax: 0, godot: 0, godotMax: 0, copy: 0, copyMax: 0, outside: 0 });
	}

	function run(request, time, frame) {
		if (request.done) {
			return;
		}
		request.done = true;
		requests.delete(request.id);
		if (!(frame && frame.session === stereo.session && referenceSpace && layer)) {
			if (stereo.session) {
				stats.outside++;
			}
			request.callback(time);
			return;
		}
		const start = performance.now();
		if (stats.last) {
			const gap = start - stats.last;
			stats.gap += gap;
			stats.gapMax = Math.max(stats.gapMax, gap);
			if (gap > 0 && gap < 100) {
				stats.gaps.push(gap);
			}
		}
		stats.last = start;
		submitted = false;
		capture(frame);
		presenting = true;
		lockHeadsetCanvas();
		let godotEnd = start;
		try {
			request.callback(time);
			godotEnd = performance.now();
		} catch (error) {
			godotEnd = performance.now();
			console.error('WebXR stereo frame failed:', error);
			// Godot did not reach its own next-frame request. Keep the headset loop alive.
			if (lastCallback) {
				const again = { id: nextRequestId++, callback: lastCallback, done: false };
				requests.set(again.id, again);
				schedule(again);
			}
		} finally {
			try {
				finishFrame();
			} catch (error) {
				console.error('WebXR stereo present failed:', error);
				paintLayer();
			}
			presenting = false;
			const end = performance.now();
			const godot = godotEnd - start;
			const copy = end - godotEnd;
			stats.frames++;
			stats.godot += godot;
			stats.godotMax = Math.max(stats.godotMax, godot);
			stats.copy += copy;
			stats.copyMax = Math.max(stats.copyMax, copy);
			report(end);
		}
	}

	function schedule(request) {
		if (stereo.session) {
			stereo.session.requestAnimationFrame((time, frame) => run(request, time, frame));
		} else {
			originalRequestAnimationFrame((time) => run(request, time, null));
		}
	}

	// Pending requests were queued on the other scheduler, which stops firing
	// (window) or disappears (session) when the session starts or ends.
	function handoff() {
		for (const request of requests.values()) {
			schedule(request);
		}
	}

	async function requestReferenceSpace(session, types) {
		for (const type of types) {
			try {
				const space = await session.requestReferenceSpace(type);
				stereo.referenceSpaceType = type;
				return space;
			} catch (error) {
				// Try the next type.
			}
		}
		throw new Error('No supported reference space.');
	}

	function describe(error) {
		return String(error && error.message ? error.message : error);
	}

	// Germ Attack races these against 3 s (VR) and 4 s (AR); some headsets answer slowly.
	function probeSupport(mode, key, wait) {
		if (!navigator.xr || !navigator.xr.isSessionSupported) {
			stereo[key] = 'no';
			return;
		}
		const timeout = new Promise((resolve) => {
			window.setTimeout(() => resolve('timeout'), wait);
		});
		const probe = navigator.xr.isSessionSupported(mode).then((yes) => (yes ? 'yes' : 'no'));
		Promise.race([probe, timeout]).then((result) => {
			stereo[key] = result;
			stage(mode + ' support ' + result);
		}).catch(() => {
			stereo[key] = 'no';
		});
	}

	// Test switches from the page URL, e.g. ?msaa=0&eyescale=0.5&shadows=0.
	stereo.param = function (name) {
		const value = new URLSearchParams(window.location.search).get(name);
		return value === null ? '' : value;
	};
	stereo.godotInfo = '';
	stereo.frameRate = 0;

	stereo.needsFallback = function () {
		if (!navigator.xr) {
			return false;
		}
		// Godot's own session renders a multiview texture array and then presents
		// the page canvas inside the XR frame. SteamVR's Chrome never finishes
		// that present, so the headset says the page isn't responding.
		if (/[?&]webxr=native\b/.test(window.location.search)) {
			return false;
		}
		return true;
	};

	// Godot's main loop asks for frames through window.requestAnimationFrame, so
	// routing it lets an active session drive Godot at the headset's frame rate.
	stereo.install = function () {
		if (installed) {
			return;
		}
		installed = true;
		gl = getCanvas().getContext('webgl2');
		hookContext(gl);
		// Finish this while the page is still drawing. After a headset session
		// starts, the page's frames stop and this call would never complete.
		if (gl && gl.makeXRCompatible) {
			gl.makeXRCompatible().catch(() => {});
		}
		probeSupport('immersive-vr', 'vrSupported', 3000);
		probeSupport('immersive-ar', 'arSupported', 4000);
		if (navigator.xr && !navigator.xr.requestSession.__shivoo) {
			const origRequestSession = navigator.xr.requestSession.bind(navigator.xr);
			const wrapped = function (mode, options) {
				sessionPending = true;
				return origRequestSession(mode, options).then((session) => {
					sessionPending = false;
					watchSession(session);
					return session;
				}, (error) => {
					sessionPending = false;
					throw error;
				});
			};
			wrapped.__shivoo = true;
			navigator.xr.requestSession = wrapped;
		}
		window.requestAnimationFrame = function (callback) {
			lastCallback = callback;
			const request = { id: nextRequestId++, callback: callback, done: false };
			requests.set(request.id, request);
			schedule(request);
			return request.id;
		};
		window.cancelAnimationFrame = function (id) {
			const request = requests.get(id);
			if (request) {
				request.done = true;
				requests.delete(id);
			}
		};
		stage('installed');
	};

	// requestSession stays synchronous with the button press so it keeps user activation.
	// local-floor and hand-tracking are optional and will not fail the session.
	// immersive-ar shows the room behind anything Godot leaves transparent.
	stereo.start = function (onStarted, onEnded, onFailed, mode) {
		if (stereo.session) {
			return;
		}
		mode = mode === 'immersive-ar' ? mode : 'immersive-vr';
		gl = getCanvas().getContext('webgl2');
		hookContext(gl);
		if (!gl) {
			onFailed('WebGL2 context is missing.');
			return;
		}
		let sessionPromise;
		try {
			sessionPromise = navigator.xr.requestSession(mode, {
				requiredFeatures: ['local'],
				optionalFeatures: ['local-floor', 'hand-tracking'],
			});
		} catch (error) {
			onFailed(describe(error));
			return;
		}
		stage('requesting ' + mode);
		sessionPromise.then(async (session) => {
			stereo.sessionMode = mode;
			let setupFailed = false;
			// Schedule the next headset frame before doing any work, and paint the
			// layer as soon as it exists. An immersive session with no frames is
			// reported as a hung page.
			const keepAlive = () => {
				if (setupFailed || referenceSpace) {
					return;
				}
				session.requestAnimationFrame(keepAlive);
				try {
					paintLayer();
				} catch (error) {
					// The layer may not exist for the first callback.
				}
			};
			session.requestAnimationFrame(keepAlive);
			try {
				stage('creating layer');
				// framebufferScaleFactor 1 matches Three.js. Its MSAA
				// already happens in Godot's eye viewports; an antialiased layer would
				// only add a second full-size multisampled buffer and resolve per frame
				// for drawing one flat quad.
				layer = new XRWebGLLayer(session, gl, {
					antialias: false,
					depth: false,
					stencil: false,
					ignoreDepthValues: true,
					framebufferScaleFactor: 1,
				});
				session.updateRenderState({ baseLayer: layer });
				paintLayer();
				stage('requesting reference space');
				referenceSpace = await requestReferenceSpace(session, ['local-floor', 'local']);
			} catch (error) {
				setupFailed = true;
				layer = null;
				referenceSpace = null;
				stereo.sessionMode = '';
				stage('setup failed');
				session.end();
				onFailed(describe(error));
				return;
			}
			session.addEventListener('end', () => {
				stereo.session = null;
				stereo.sessionMode = '';
				stereo.frameJson = '';
				referenceSpace = null;
				layer = null;
				viewports = [];
				presenting = false;
				stereo.frameRate = 0;
				stats.last = 0;
				stats.gaps.length = 0;
				unlockHeadsetCanvas();
				stage('ended');
				handoff();
				onEnded();
			});
			stereo.session = session;
			watchGestures(session);
			if (requests.size === 0 && lastCallback) {
				const request = { id: nextRequestId++, callback: lastCallback, done: false };
				requests.set(request.id, request);
			}
			handoff();
			stage('running ' + stereo.referenceSpaceType);
			onStarted(stereo.referenceSpaceType);
		}).catch((error) => {
			stage('session failed');
			onFailed(describe(error));
		});
	};

	stereo.end = function () {
		if (stereo.session) {
			stereo.session.end();
		}
	};

	// Exposed so a headset's hand joints can be read over devtools without a session.
	stereo.handGesture = handGesture;
	window.ShivooStereo = stereo;
})();
