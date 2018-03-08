package hxd.snd;

import hxd.snd.Driver;
import haxe.MainLoop;

@:access(hxd.snd.Manager)
class Source {
	static var ID = 0;

	public var id (default, null) : Int;
	public var handle  : SourceHandle;
	public var channel : Channel;
	public var buffers : Array<Buffer>;

	public var volume  = -1.0;
	public var playing = false;
	public var start   = 0;

	public function new(driver : Driver) {
		id      = ID++;
		handle  = driver.createSource();
		buffers = [];
	}

	public function dispose() {
		Manager.get().driver.destroySource(handle);
	}
}

@:access(hxd.snd.Manager)
class Buffer {
	public var handle   : BufferHandle;
	public var sound    : hxd.res.Sound;
	public var isEnd    : Bool;
	public var isStream : Bool;
	public var refs     : Int;
	public var lastStop : Float;

	public var start      : Int;
	public var samples    : Int;
	public var sampleRate : Int;

	public function new(driver : Driver) {
		handle = driver.createBuffer();
		refs = 0;
		lastStop = haxe.Timer.stamp();
	}

	public function dispose() {
		Manager.get().driver.destroyBuffer(handle);
	}
}

class Manager {
	// Automatically set the channel to streaming mode if its duration exceed this value.
	public static var STREAM_DURATION            = 5.;
	public static var STREAM_BUFFER_SAMPLE_COUNT = 44100;
	public static var MAX_SOURCES                = 16;
	public static var SOUND_BUFFER_CACHE_SIZE    = 256;

	static var instance : Manager;

	public var masterVolume	: Float;
	public var masterSoundGroup   (default, null) : SoundGroup;
	public var masterChannelGroup (default, null) : ChannelGroup;
	public var listener : Listener;

	var updateEvent   : MainEvent;

	var cachedBytes   : haxe.io.Bytes;
	var resampleBytes : haxe.io.Bytes;

	var driver   : Driver;
	var channels : Channel;
	var sources  : Array<Source>;
	var now      : Float;

	var soundBufferCount  : Int;
	var soundBufferMap    : Map<String, Buffer>;
	var freeStreamBuffers : Array<Buffer>;
	var effectGC          : Array<Effect>;

	private function new() {
		try {
			#if usesys
			driver = new haxe.AudioTypes.SoundDriver();
			#else
			driver = new hxd.snd.openal.Driver();
			#end
		} catch(e : String) {
			driver = null;
		}

		masterVolume       = 1.0;
		masterSoundGroup   = new SoundGroup  ("master");
		masterChannelGroup = new ChannelGroup("master");
		listener           = new Listener();
		soundBufferMap     = new Map();
		freeStreamBuffers  = [];
		effectGC           = [];
		soundBufferCount   = 0;

		if (driver != null) {
			// alloc sources
			sources = [];
			for (i in 0...MAX_SOURCES) sources.push(new Source(driver));
		}

		cachedBytes   = haxe.io.Bytes.alloc(4 * 3 * 2);
		resampleBytes = haxe.io.Bytes.alloc(STREAM_BUFFER_SAMPLE_COUNT * 2);
	}

	function getTmpBytes(size) {
		if (cachedBytes.length < size)
			cachedBytes = haxe.io.Bytes.alloc(size);
		return cachedBytes;
	}

	function getResampleBytes(size : Int) {
		if (resampleBytes.length < size)
			resampleBytes = haxe.io.Bytes.alloc(size);
		return resampleBytes;
	}

	public static function get() : Manager {
		if( instance == null ) {
			instance = new Manager();
			instance.updateEvent = haxe.MainLoop.add(instance.update);
			#if (haxe_ver >= 4) instance.updateEvent.isBlocking = false; #end
		}
		return instance;
	}

	public function stopAll() {
		while( channels != null )
			channels.stop();
	}

	public function cleanCache() {
		for (k in soundBufferMap.keys()) {
			var b = soundBufferMap.get(k);
			if (b.refs > 0) continue;
			soundBufferMap.remove(k);
			b.dispose();
			--soundBufferCount;
		}
	}

	public function dispose() {
		stopAll();

		if (driver != null) {
			for (s in sources)           s.dispose();
			for (b in soundBufferMap)    b.dispose();
			for (b in freeStreamBuffers) b.dispose();
			for (e in effectGC)          e.driver.release();
			driver.dispose();
		}

		sources           = null;
		soundBufferMap    = null;
		freeStreamBuffers = null;
		effectGC          = null;

		updateEvent.stop();
		instance = null;
	}

	public function play(sound : hxd.res.Sound, ?channelGroup : ChannelGroup, ?soundGroup : SoundGroup) {
		if (soundGroup   == null) soundGroup   = masterSoundGroup;
		if (channelGroup == null) channelGroup = masterChannelGroup;

		var c = new Channel();
		c.sound        = sound;
		c.duration     = sound.getData().duration;
		c.manager      = this;
		c.soundGroup   = soundGroup;
		c.channelGroup = channelGroup;
		c.next         = channels;
		c.isVirtual    = (driver == null);

		channels = c;
		return c;
	}

	function updateVirtualChannels(now : Float) {
		var c = channels;
		while (c != null) {
			if (c.pause || !c.isVirtual) {
				c = c.next;
				continue;
			}

			c.position += now - c.lastStamp;
			c.lastStamp = now;

			var next = c.next; // save next, since we might release this channel
			while (c.position >= c.duration) {
				c.position -= c.duration;
				c.onEnd();

				if (c.queue.length > 0) {
					c.sound = c.queue.shift();
					c.duration = c.sound.getData().duration;
				} else if (!c.loop) {
					releaseChannel(c);
					break;
				}
			}
			c = next;
		}
	}

	public function update() {
		now = haxe.Timer.stamp();

		if (driver == null) {
			updateVirtualChannels(now);
			return;
		}

		// --------------------------------------------------------------------
		// (de)queue buffers, sync positions & release ended channels
		// --------------------------------------------------------------------

		for (s in sources) {
			var c = s.channel;
			if (c == null) continue;

			// did the user changed the position?
			if (c.positionChanged) {
				releaseSource(s);
				continue;
			}

			// process consumed buffers
			var lastBuffer = null;
			var count = driver.getProcessedBuffers(s.handle);
			for (i in 0...count) {
				var b = unqueueBuffer(s);
				lastBuffer = b;
				if (b.isEnd) {
					c.sound           = b.sound;
					c.duration        = b.sound.getData().duration;
					c.position        = c.duration;
					c.positionChanged = false;
					c.onEnd();
					s.start = 0;
				}
			}

			// did the source consumed all buffers?
			if (s.buffers.length == 0) {
				if (!lastBuffer.isEnd) {
					c.position = (lastBuffer.start + lastBuffer.samples) / lastBuffer.sampleRate;
					releaseSource(s);
				} else if (c.queue.length > 0) {
					c.sound    = c.queue[0];
					c.duration = c.sound.getData().duration;
					c.position = 0;
					releaseSource(s);
				} else if (c.loop) {
					c.position = 0;
					releaseSource(s);
				} else {
					releaseChannel(c);
				}
				continue;
			}

			// sync channel position
			c.sound    = s.buffers[0].sound;
			c.duration = c.sound.getData().duration;
			c.position = (s.start + driver.getPlayedSampleCount(s.handle)) / s.buffers[0].sampleRate;
			c.positionChanged = false;

			// enqueue next buffers
			if (s.buffers.length < 2) {
				var b = s.buffers[s.buffers.length - 1];
				if (!b.isEnd) {
					// next stream buffer
					queueBuffer(s, b.sound, b.start + b.samples);
				} else if (c.queue.length > 0) {
					// queue next sound buffer
					queueBuffer(s, c.queue.shift(), 0);
				} else if (c.loop) {
					// requeue last played sound
					queueBuffer(s, b.sound, 0);
				}
			}
		}

		// --------------------------------------------------------------------
		// calc audible gain & virtualize inaudible channels
		// --------------------------------------------------------------------

		var c = channels;
		while (c != null) {
			c.calcAudibleGain(now);
			c.isVirtual = c.pause || c.mute || c.channelGroup.mute || c.audibleGain < 1e-5;
			c = c.next;
		}

		// --------------------------------------------------------------------
		// sort channels by priority
		// --------------------------------------------------------------------

		channels = haxe.ds.ListSort.sortSingleLinked(channels, sortChannel);

		// --------------------------------------------------------------------
		// virtualize sounds that puts the put the audible count over the maximum number of sources
		// --------------------------------------------------------------------

		var sgroupRefs = new Map<SoundGroup, Int>();
		var audibleCount = 0;
		var c = channels;
		while (c != null && !c.isVirtual) {
			if (++audibleCount > sources.length) c.isVirtual = true;
			else if (c.soundGroup.maxAudible >= 0) {
				var sgRefs = sgroupRefs.get(c.soundGroup);
				if (sgRefs == null) sgRefs = 0;
				if (++sgRefs > c.soundGroup.maxAudible) {
					c.isVirtual = true;
					--audibleCount;
				}
				sgroupRefs.set(c.soundGroup, sgRefs);
			}
			c = c.next;
		}

		// --------------------------------------------------------------------
		// free sources that points to virtualized channels
		// --------------------------------------------------------------------

		for (s in sources) {
			if (s.channel == null || !s.channel.isVirtual) continue;
			releaseSource(s);
		}

		// --------------------------------------------------------------------
		// bind non-virtual channels to sources
		// --------------------------------------------------------------------

		var c = channels;
		while (c != null) {
			if (c.source != null || c.isVirtual) {
				c = c.next;
				continue;
			}

			// look for a free source
			var s = null;
			for (s2 in sources) if( s2.channel == null ) {
				s = s2;
				break;
			}

			if (s == null) throw "could not get a source";
			s.channel = c;
			c.source = s;

			checkTargetFormat(c.sound.getData(), c.soundGroup.mono);
			s.start = Math.ceil(c.position * targetRate);
			queueBuffer(s, c.sound, s.start);
			c.positionChanged = false;
			c = c.next;
		}

		// --------------------------------------------------------------------
		// update source parameters
		// --------------------------------------------------------------------

		var usedEffects : Effect = null;
		for (s in sources) {
			var c = s.channel;
			if (c == null) continue;

			var v = c.currentVolume;
			if (s.volume != v) {
				s.volume = v;
				driver.setSourceVolume(s.handle, v);
			}

			if (!s.playing) {
				driver.playSource(s.handle);
				s.playing = true;
			}

			// unbind removed effects
			var i = c.bindedEffects.length;
			while (--i >= 0) {
				var e = c.bindedEffects[i];
				if (c.effects.indexOf(e) < 0 && c.channelGroup.effects.indexOf(e) < 0)
					unbindEffect(c, s, e);
			}

			// bind added effects
			for (e in c.channelGroup.effects) if (c.bindedEffects.indexOf(e) < 0) bindEffect(c, s, e);
			for (e in c.effects) if (c.bindedEffects.indexOf(e) < 0) bindEffect(c, s, e);

			// register used effects
			for (e in c.bindedEffects) usedEffects = regEffect(usedEffects, e);
		}

		// --------------------------------------------------------------------
		// update effects
		// --------------------------------------------------------------------

		usedEffects = haxe.ds.ListSort.sortSingleLinked(usedEffects, sortEffect);
		var e = usedEffects;
		while (e != null) {
			e.driver.update(e);
			e = e.next;
		}

		for (s in sources) {
			var c = s.channel;
			if (c == null) continue;
			for (e in c.bindedEffects) e.driver.apply(e, s.handle);
		}

		for (e in effectGC) if (now - e.lastStamp > e.retainTime) {
			e.driver.release();
			effectGC.remove(e);
			break;
		}

		// --------------------------------------------------------------------
		// update virtual channels
		// --------------------------------------------------------------------

		updateVirtualChannels(now);

		// --------------------------------------------------------------------
		// update global driver parameters
		// --------------------------------------------------------------------

		listener.direction.normalize();
		listener.up.normalize();

		driver.setMasterVolume(masterVolume);
		driver.setListenerParams(listener.position, listener.direction, listener.up, listener.velocity);

		driver.update();

		// --------------------------------------------------------------------
		// sound buffer cache GC
		// --------------------------------------------------------------------

		// TODO : avoid alloc from map.keys()
		if (soundBufferCount >= SOUND_BUFFER_CACHE_SIZE) {
			var now = haxe.Timer.stamp();
			for (k in soundBufferMap.keys()) {
				var b = soundBufferMap.get(k);
				if (b.refs > 0 || b.lastStop + 60.0 > now) continue;
				soundBufferMap.remove(k);
				b.dispose();
				--soundBufferCount;
			}
		}
	}

	// ------------------------------------------------------------------------
	// internals
	// ------------------------------------------------------------------------

	function queueBuffer(s : Source, snd : hxd.res.Sound, start : Int) {
		var data   = snd.getData();
		var sgroup = s.channel.soundGroup;

		var b : Buffer = null;
		if (data.duration <= STREAM_DURATION) {
			// queue sound buffer
			b = getSoundBuffer(snd, sgroup);
			driver.queueBuffer(s.handle, b.handle, start, true);
		} else {
			// queue stream buffer
			b = getStreamBuffer(snd, sgroup, start);
			driver.queueBuffer(s.handle, b.handle, 0, b.isEnd);
		}
		s.buffers.push(b);
		return b;
	}

	function unqueueBuffer(s : Source) {
		var b = s.buffers.shift();
		driver.unqueueBuffer(s.handle, b.handle);
		if (b.isStream) freeStreamBuffers.unshift(b);
		else if (--b.refs == 0) b.lastStop = haxe.Timer.stamp();
		return b;
	}

	static function regEffect(list : Effect, e : Effect) : Effect {
		var l = list;
		while (l != null) {
			if (l == e) return list;
			l = l.next;
		}
		e.next = list;
		return e;
	}

	function bindEffect(c : Channel, s : Source, e : Effect) {
		var wasInGC = effectGC.remove(e);
		if (!wasInGC && e.refs == 0) e.driver.acquire();
		++e.refs;
		e.driver.bind(e, s.handle);
		c.bindedEffects.push(e);
	}

	function unbindEffect(c : Channel, s : Source, e : Effect) {
		e.driver.unbind(e, s.handle);
		c.bindedEffects.remove(e);
		if (--e.refs == 0) {
			e.lastStamp = now;
			effectGC.push(e);
		}
	}

	function releaseSource(s : Source) {
		if (s.channel != null) {
			for (e in s.channel.bindedEffects.copy()) unbindEffect(s.channel, s, e);
			s.channel.bindedEffects = [];
			s.channel.source = null;
			s.channel = null;
		}

		if (s.playing) {
			s.playing = false;
			driver.stopSource(s.handle);
			s.volume = -1.0;
		}

		while(s.buffers.length > 0) unqueueBuffer(s);
	}

	var targetRate     : Int;
	var targetFormat   : Data.SampleFormat;
	var targetChannels : Int;

	function checkTargetFormat(dat : hxd.snd.Data, forceMono = false) {
		targetRate = dat.samplingRate;
		#if (!usesys && !hlopenal)
		// perform resampling to nativechannel frequency
		targetRate = hxd.snd.openal.Emulator.NATIVE_FREQ;
		#end
		targetChannels = forceMono || dat.channels == 1 ? 1 : 2;
		targetFormat   = switch (dat.sampleFormat) {
			case UI8 : UI8;
			case I16 : I16;
			case F32 : I16;
		}
		return targetChannels == dat.channels && targetFormat == dat.sampleFormat && targetRate == dat.samplingRate;
	}

	function getSoundBuffer(snd : hxd.res.Sound, grp : SoundGroup) : Buffer {
		var data = snd.getData();
		var mono = grp.mono;
		var key  = snd.entry.path;

		if (mono && data.channels != 1) key += "mono";
		var b = soundBufferMap.get(key);
		if (b == null) {
			b = new Buffer(driver);
			b.isStream = false;
			b.isEnd = true;
			b.sound = snd;
			soundBufferMap.set(key, b);
			data.load(function() fillSoundBuffer(b, data, mono));
			++soundBufferCount;
		}

		++b.refs;
		return b;
	}

	function fillSoundBuffer(buf : Buffer, dat : hxd.snd.Data, forceMono = false) {
		if (!checkTargetFormat(dat, forceMono))
			dat = dat.resample(targetRate, targetFormat, targetChannels);

		var length = dat.samples * dat.getBytesPerSample();
		var bytes  = getTmpBytes(length);
		dat.decode(bytes, 0, 0, dat.samples);
		driver.setBufferData(buf.handle, bytes, length, targetFormat, targetChannels, targetRate);
		buf.sampleRate = targetRate;
		buf.samples    = dat.samples;
	}

	function getStreamBuffer(snd : hxd.res.Sound, grp : SoundGroup, start : Int) : Buffer {
		var data = snd.getData();

		var b = freeStreamBuffers.shift();
		if (b == null) {
			b = new Buffer(driver);
			b.isStream = true;
		}

		var samples = STREAM_BUFFER_SAMPLE_COUNT;
		if (start + samples >= data.samples) {
			samples = data.samples - start;
			b.isEnd = true;
		} else {
			b.isEnd = false;
		}

		b.sound   = snd;
		b.samples = samples;
		b.start   = start;

		var size  = samples * data.getBytesPerSample();
		var bytes = getTmpBytes(size);
		data.decode(bytes, 0, start, samples);

		if (!checkTargetFormat(data, grp.mono)) {
			size = samples * targetChannels * Data.formatBytes(targetFormat);
			var resampleBytes = getResampleBytes(size);
			data.resampleBuffer(resampleBytes, 0, bytes, 0, targetRate, targetFormat, targetChannels, samples);
			bytes = resampleBytes;
		}

		driver.setBufferData(b.handle, bytes, size, targetFormat, targetChannels, targetRate);
		b.sampleRate = targetRate;
		return b;
	}

	function sortChannel(a : Channel, b : Channel) {
		if (a.isVirtual != b.isVirtual)
			return a.isVirtual ? 1 : -1;

		if (a.channelGroup.priority != b.channelGroup.priority)
			return a.channelGroup.priority < b.channelGroup.priority ? 1 : -1;

		if (a.priority != b.priority)
			return a.priority < b.priority ? 1 : -1;

		if (a.audibleGain != b.audibleGain)
			return a.audibleGain < b.audibleGain ? 1 : -1;

		return a.id < b.id ? 1 : -1;
	}

	function sortEffect(a : Effect, b : Effect) {
		return b.priority - a.priority;
	}

	function releaseChannel(c : Channel) {
		if (channels == c) {
			channels = c.next;
		} else {
			var prev = channels;
			while (prev.next != c)
				prev = prev.next;
			prev.next = c.next;
		}

		for (e in c.effects) c.removeEffect(e);
		if (c.source != null) releaseSource(c.source);
		c.next = null;
		c.manager = null;
		c.effects = null;
		c.bindedEffects = null;
	}
}