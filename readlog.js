const NSData = ObjC.classes.NSData;
const paths = [
  '/var/mobile/Library/Logs/freqmon-dump.log',
  '/var/mobile/Library/Logs/freqmon.log'
];
paths.forEach(function (p) {
  const d = NSData.dataWithContentsOfFile_(p);
  if (!d) { console.log(p + ': (nil)'); return; }
  const len = d.length();
  console.log('=== ' + p + ' size=' + len + ' ===');
  if (len > 0) {
    const s = Memory.alloc(len + 1);
    const b = d.bytes();
    for (let i = 0; i < len; i++) s.add(i).writeU8(b.add(i).readU8());
    s.add(len).writeU8(0);
    console.log(s.readUtf8String().substring(0, 8000));
  }
});
console.log('DONE');