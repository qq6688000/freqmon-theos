const FM = ObjC.classes.NSFileManager.defaultManager();
// 用 NSFileManager 的 subpathsOfDirectoryAtPath 尝试列 /var/jb
const candidates = ['/var/jb', '/var/containers/Bundle/Application'];
candidates.forEach(function (base) {
  console.log('=== ' + base + ' ===');
  const e = FM.fileExistsAtPath_(base);
  console.log(' exists=' + e);
  if (e) {
    // 尝试 subpaths（可能大，限制）
    try {
      const sp = FM.subpathsOfDirectoryAtPath_error_(base, NULL);
      if (sp) {
        console.log(' subpaths count=' + sp.count());
        for (let i = 0; i < sp.count(); i++) {
          const s = sp.objectAtIndex_(i).toString();
          if (/SquidGesture|FreqMon|TweakInject|DynamicLibraries/.test(s)) console.log('  ' + s);
        }
      } else console.log(' subpaths nil');
    } catch (e2) { console.log(' subpaths err ' + e2); }
  }
});
console.log('DONE');