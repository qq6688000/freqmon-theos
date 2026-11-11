const FM = ObjC.classes.NSFileManager.defaultManager();
const paths = [
  '/var/jb/Library/MobileSubstrate/DynamicLibraries',
  '/var/containers/Bundle/Application/.jbroot-6837AAC9D401CC25/Library/MobileSubstrate/DynamicLibraries',
  '/var/containers/Bundle/Application/.jbroot-6837AAC9D401CC25/usr/lib/TweakInject'
];
paths.forEach(function (p) {
  const e = FM.fileExistsAtPath_(p);
  console.log(p + ' => ' + e);
  if (e) {
    const a = FM.contentsOfDirectoryAtPath_error_(p, NULL);
    if (a) {
      const n = a.count(); let names = [];
      for (let i = 0; i < n && i < 40; i++) names.push(a.objectAtIndex_(i).toString());
      console.log('   [' + n + '] ' + names.join(', '));
    } else console.log('   (readdir nil)');
  }
});
console.log('DONE');