const IOServiceMatching = new NativeFunction(Module.findExportByName(null, 'IOServiceMatching'), 'pointer', ['pointer']);
const IOServiceGetMatchingService = new NativeFunction(Module.findExportByName(null, 'IOServiceGetMatchingService'), 'uint', ['uint', 'pointer']);
const IORegistryEntryCreateCFProperties = new NativeFunction(Module.findExportByName(null, 'IORegistryEntryCreateCFProperties'), 'int', ['uint', 'pointer', 'pointer', 'uint']);
const IOObjectRelease = new NativeFunction(Module.findExportByName(null, 'IOObjectRelease'), 'int', ['uint']);

function propsOf(entry) {
  const ref = Memory.alloc(8);
  const r = IORegistryEntryCreateCFProperties(entry, ref, NULL, 0);
  if (r !== 0 || ref.readPointer().isNull()) return null;
  try { return new ObjC.Object(ref.readPointer()); } catch (e) { return null; }
}

const classes = ['AppleCLPC', 'AppleARMIODevice', 'AppleT8120PMGR', 'AGXAccelerator', 'ApplePMGR'];
for (const cls of classes) {
  const m = IOServiceMatching(Memory.allocUtf8String(cls));
  if (m.isNull()) { console.log(cls + ': no match'); continue; }
  const entry = IOServiceGetMatchingService(0, m);
  console.log('=== ' + cls + ' entry=0x' + entry.toString(16) + ' ===');
  if (entry) {
    const props = propsOf(entry);
    if (props) {
      const ks = props.allKeys().toString();
      console.log('    keys: ' + ks.substring(0, 500));
      for (const k of ['DVFMStates','CurrentStates','MinState','MaxState','voltage-states','performance-states','ApplePMGRPCPUFixedFreq','ApplePMGRECPUFixedFreq','voltage-states1','voltage-states5','voltage-states9','TargetStates','IOReportGroupName','perf-states']) {
        if (ks.indexOf(k) >= 0) {
          const v = props.objectForKey_(k);
          console.log('    ' + k + ' = ' + (v ? v.toString().substring(0, 350) : 'nil'));
        }
      }
    }
    IOObjectRelease(entry);
  }
}
console.log('DONE');
