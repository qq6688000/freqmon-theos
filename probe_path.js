// 从 IODeviceTree 找 /arm-io/pmgr 节点，读 DVFMStates/CurrentStates
const IORegistryEntryFromPath = new NativeFunction(Module.findExportByName(null, 'IORegistryEntryFromPath'), 'uint', ['uint', 'pointer']);
const IORegistryEntryCreateCFProperties = new NativeFunction(Module.findExportByName(null, 'IORegistryEntryCreateCFProperties'), 'int', ['uint', 'pointer', 'pointer', 'uint']);
const IOObjectRelease = new NativeFunction(Module.findExportByName(null, 'IOObjectRelease'), 'int', ['uint']);

function propsOf(entry) {
  const ref = Memory.alloc(8);
  const r = IORegistryEntryCreateCFProperties(entry, ref, NULL, 0);
  if (r !== 0 || ref.readPointer().isNull()) return null;
  try { return new ObjC.Object(ref.readPointer()); } catch (e) { return null; }
}

const paths = ['IODeviceTree:/arm-io/pmgr', 'IODeviceTree:/arm-io', 'IOService:/AppleT8120PMGR'];
for (const p of paths) {
  const entry = IORegistryEntryFromPath(0, Memory.allocUtf8String(p));
  console.log('=== ' + p + ' entry=0x' + entry.toString(16) + ' ===');
  if (entry) {
    const props = propsOf(entry);
    if (props) {
      const ks = props.allKeys().toString();
      console.log('    keys: ' + ks.substring(0, 600));
      for (const k of ['DVFMStates','CurrentStates','DVFMTable','ApplePMGRPCPUFixedFreq','ApplePMGRECPUFixedFreq','MinState','MaxState','TargetStates','perf-states','voltage-states1','voltage-states5','voltage-states9']) {
        if (ks.indexOf(k) >= 0) {
          const v = props.objectForKey_(k);
          console.log('    ' + k + ' = ' + (v ? v.toString().substring(0, 500) : 'nil'));
        }
      }
    }
    IOObjectRelease(entry);
  }
}
console.log('DONE');
