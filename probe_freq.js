// 探测 CPU/GPU 频率来源
var out = [];

// 1) sysctl 频率
var sysctlbyname = new NativeFunction(Module.findExportByName(null, 'sysctlbyname'), 'int', ['pointer', 'pointer', 'pointer', 'pointer', 'int']);
function sysctlInt(name) {
  var nm = Memory.allocUtf8String(name);
  var val = Memory.alloc(8); var sz = Memory.alloc(8); sz.writeU64(8);
  var r = sysctlbyname(nm, val, sz, NULL, 0);
  return r === 0 ? val.readU64() : -1;
}
['hw.cpufrequency', 'hw.cpufrequency_max', 'hw.cpufrequency_min', 'hw.busfrequency', 'hw.memfrequency', 'hw.l2cachesize'].forEach(function(n) {
  out.push('sysctl ' + n + ' = ' + sysctlInt(n));
});

// 2) sysctl string
function sysctlStr(name) {
  var nm = Memory.allocUtf8String(name);
  var sz = Memory.alloc(8); sz.writeU64(0);
  sysctlbyname(nm, NULL, sz, NULL, 0);
  var s = sz.readU64();
  if (s === 0) return '(nil)';
  var buf = Memory.alloc(s);
  sysctlbyname(nm, buf, sz, NULL, 0);
  return buf.readUtf8String();
}
out.push('hw.machine = ' + sysctlStr('hw.machine'));
out.push('hw.model = ' + sysctlStr('hw.model'));
out.push('hw.cpusubtype = ' + sysctlInt('hw.cpusubtype'));

// 3) IORegistry: AppleARMIODevice voltage-states (CPU 频率表)
var kIOMasterPortDefault = 0;
var IOServiceMatching = new NativeFunction(Module.findExportByName(null, 'IOServiceMatching'), 'pointer', ['pointer']);
var IOServiceGetMatchingServices = new NativeFunction(Module.findExportByName(null, 'IOServiceGetMatchingServices'), 'int', ['int', 'pointer', 'pointer']);
var IOIteratorNext = new NativeFunction(Module.findExportByName(null, 'IOIteratorNext'), 'int', ['int']);
var IOObjectRelease = new NativeFunction(Module.findExportByName(null, 'IOObjectRelease'), 'int', ['int']);
var IORegistryEntryCreateCFProperties = new NativeFunction(Module.findExportByName(null, 'IORegistryEntryCreateCFProperties'), 'int', ['int', 'pointer', 'pointer', 'int']);
var IORegistryEntryGetName = new NativeFunction(Module.findExportByName(null, 'IORegistryEntryGetName'), 'int', ['int', 'pointer']);
var kCFAllocatorDefault = Module.findExportByName(null, 'kCFAllocatorDefault');

function dumpIOService(className, maxEntries) {
  var match = IOServiceMatching(Memory.allocUtf8String(className));
  if (match.isNull()) { out.push('  ' + className + ': no match'); return; }
  var iter = Memory.alloc(4);
  var r = IOServiceGetMatchingServices(kIOMasterPortDefault, match, iter);
  if (r !== 0) { out.push('  ' + className + ': getMatchingServices rc=' + r); return; }
  var it = iter.readU32();
  var n = 0;
  while (n < maxEntries) {
    var entry = IOIteratorNext(it);
    if (entry === 0) break;
    // 读名字
    var nameBuf = Memory.alloc(128);
    IORegistryEntryGetName(entry, nameBuf);
    var name = nameBuf.readUtf8String();
    
    // 读属性
    var propsPtr = Memory.alloc(8);
    r = IORegistryEntryCreateCFProperties(entry, propsPtr, kCFAllocatorDefault, 0);
    if (r === 0) {
      var props = propsPtr.readPointer();
      if (!props.isNull()) {
        var dict = new ObjC.Object(props);
        var keys = dict.allKeys();
        var interesting = [];
        for (var i = 0; i < keys.count(); i++) {
          var k = keys.objectAtIndex_(i).toString();
          if (/freq|speed|hz|mhz|ghz|voltage|state|perf|util|power|clock|mhz|khz|rate/i.test(k)) {
            var v = dict.objectForKey_(keys.objectAtIndex_(i));
            var vs = v ? v.toString().substring(0, 200) : '(nil)';
            interesting.push(k + '=' + vs);
          }
        }
        if (interesting.length) out.push('  [' + className + ' #' + n + '] ' + name + ': ' + interesting.join(' | '));
        else out.push('  [' + className + ' #' + n + '] ' + name + ': (no freq keys, ' + keys.count() + ' props)');
      }
    }
    IOObjectRelease(entry);
    n++;
  }
  IOObjectRelease(it);
}

out.push('=== IORegistry scan ===');
['AppleARMIODevice', 'AppleARMPE', 'AppleCLPC', 'AppleT8120PMGR', 'ApplePMGR', 'AGXAccelerator', 'AppleGPU', 'IOGPU'].forEach(function(c) {
  try { dumpIOService(c, 3); } catch(e) { out.push('  ' + c + ' ERR: ' + e); }
});

console.log(out.join('\n'));