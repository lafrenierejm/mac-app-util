# A minimal app for testing signed copies by hand (see tests/e2e-fda.sh).
#
# It tries to read a file that is only readable with Full Disk Access and
# reports whether that worked: in a dialog, or in the file named by its first
# argument.  Building it with different versions simulates an app update: the
# binary, and so its ad-hoc code hash, differs.
{
  lib,
  stdenv,
  writeText,
  version,
}:

stdenv.mkDerivation {
  pname = "mac-app-util-test-app";
  inherit version;
  dontUnpack = true;
  src = writeText "test-app.c" ''
    #include <errno.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>

    int main(int argc, char **argv) {
      const char *home = getenv("HOME");
      char path[1024], msg[1200], cmd[1400];
      snprintf(path, sizeof path,
               "%s/Library/Application Support/com.apple.TCC/TCC.db",
               home ? home : "");
      FILE *f = fopen(path, "r");
      snprintf(msg, sizeof msg, "TestApp v%s: Full Disk Access %s",
               VERSION,
               f ? "GRANTED" : (errno == EPERM || errno == EACCES
                                    ? "DENIED"
                                    : strerror(errno)));
      if (f) fclose(f);
      /* With a path argument, report there instead of via dialog. */
      if (argc > 1) {
        FILE *o = fopen(argv[1], "w");
        if (!o) return 2;
        fprintf(o, "%s\n", msg);
        fclose(o);
        return 0;
      }
      puts(msg);
      snprintf(cmd, sizeof cmd,
               "/usr/bin/osascript -e 'display alert \"%s\"'", msg);
      return system(cmd);
    }
  '';
  buildPhase = ''
    runHook preBuild
    $CC -DVERSION='"${version}"' -x c "$src" -o TestApp
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    app="$out/Applications/TestApp.app/Contents"
    mkdir -p "$app/MacOS"
    install -m755 TestApp "$app/MacOS/TestApp"
    cat > "$app/Info.plist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key><string>TestApp</string>
      <key>CFBundleIdentifier</key><string>xyz.mac-app-util.test-app</string>
      <key>CFBundleName</key><string>TestApp</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>${version}</string>
      <key>LSBackgroundOnly</key><true/>
    </dict>
    </plist>
    EOF
    runHook postInstall
  '';
  meta.license = lib.licenses.agpl3Only;
}
