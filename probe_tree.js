// 从 root 走 IORegistry 树找到 pmgr/clpc 节点，读 DVFMStates/CurrentStates
const IOServiceGetMatchingService = new NativeFunction(Module.findExportByName(null, 'IOServiceGetMatchingService'), 'uint', ['uint', 'pointer']);
const IOServiceMatching = new NativeFunction(Module.findExportByName(null, 'IOServiceMatching'), 'pointer', ['pointer']);
const IORegistryEntryCreateCFProperties = new NativeFunction(Module.findExportByName(null, 'IORegistryEntryCreateCFProperties'), 'int', ['uint', 'pointer', 'pointer', 'uint']);
const IORegistryEntryGetChildEntry = new NativeFunction(Module.findExportByName(null, 'IORegistryEntryGetChildEntry'), 'int', ['uint', 'pointer', 'pointer']);
const IOObjectRelease = new NativeFunction(Module.findExportByName(null, 'IOObjectRelease'), 'int', ['uint']);
const IORegistryEntryGetName = new NativeFunction(Module.findExportByName(null, 'IORegistryEntryGetName'), 'pointer', ['uint']);

function propsOf(entry) {
  const ref = Memory.alloc(8);
  const r = IORegistryEntryCreateCFProperties(entry, ref, NULL, 0);
  if (r !== 0 || ref.readPointer().isNull()) return null;
  try { return new ObjC.Object(ref.readPointer()); } catch (e) { return null; }
}
function walk(entry, depth, maxDepth, targetNames) {
  if (depth > maxDepth) return;
  const plane = Memory.allocUtf8String('IOService');
  const child = Memory.alloc(8);
  const kr = IORegistryEntryGetChildEntry(entry, plane, child);
  if (kr !== 0) return;
  let c = child.readUInt();
  while (c) {
    const nm = IORegistryEntryGetName(c);
    let nmStr = '?';
    try { if (!nm.isNull()) nmStr = nm.readUtf8String(); } catch (e) {}
    const props = propsOf(c);
    let ks = '';
    if (props) { try { ks = props.allKeys().toString(); } catch (e) {} }
    if (targetNames.length === 0 || targetNames.indexOf(nmStr) >= 0 || /DVFM|Current|FixedFreq|voltage/i.test(ks)) {
      console.log('  '.repeat(depth) + nmStr + ' -> ' + ks.substring(0, 200));
      if (props && /DVFM|Current|FixedFreq|voltage/i.test(ks)) {
        for (const k of ['DVFMStates','CurrentStates','MinState','MaxState','ApplePMGRPCPUFixedFreq','ApplePMGRECPUFixedFreq','voltage-states1','voltage-states5','voltage-states9','TargetStates','perf-states']) {
          if (ks.indexOf(k) >= 0) {
            const v = props.objectForKey_(k);
            console.log('  '.repeat(depth) + '    ' + k + ' = ' + (v ? v.toString().substring(0, 250) : 'nil'));
          }
        }
      }
    }
    walk(c, depth + 1, maxDepth, targetNames);
    IOObjectRelease(c);
    const next = Memory.alloc(8);
    const kr2 = IORegistryEntryGetChildEntry(entry, plane, next);
    if (kr2 !== 0) break;
    c = next.readUInt();
    if (c === child.readUInt()) break;
  }
}

// 从 AppleT8120PMGR 开始遍历
const m = IOServiceMatching(Memory.allocUtf8String('AppleT8120PMGR'));
const pmgr = IOServiceGetMatchingService(0, m);
console.log('PMGR entry=0x' + pmgr.toString(16));
walk(pmgr, 0, 4, ['DVFM', 'PMGR', 'CLPC', 'clpc', 'pmgr']);
console.log('DONE');
