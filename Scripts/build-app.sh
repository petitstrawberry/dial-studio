#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/dist/Dial Studio.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
cp "$bin_dir/DialStudio" "$app_dir/Contents/MacOS/DialStudio"
cp "$bin_dir/ulanzid" "$app_dir/Contents/MacOS/ulanzid"
cp Support/Info.plist "$app_dir/Contents/Info.plist"
for localization in en ja; do
    mkdir -p "$app_dir/Contents/Resources/$localization.lproj"
    cp "Support/$localization.lproj/Localizable.strings" "$app_dir/Contents/Resources/$localization.lproj/"
    cp "Support/$localization.lproj/InfoPlist.strings" "$app_dir/Contents/Resources/$localization.lproj/"
done
if [[ ! -s Support/AppIcon.icns ]]; then
    print -u2 "アプリアイコン Support/AppIcon.icns が見つからないか空です。"
    exit 1
fi
cp Support/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
adapter="$PWD/Support/MediaRemoteAdapter"
adapter_resources="$app_dir/Contents/Resources/MediaRemoteAdapter"
cp "$adapter/mediaremote-adapter.pl" "$adapter/LICENSE" "$adapter_resources/"
xcrun clang -dynamiclib -fobjc-arc -fvisibility=default -arch arm64 -arch x86_64 \
    -I "$adapter/include" -I "$adapter/src" \
    "$adapter"/src/adapter/*.m "$adapter"/src/private/*.m "$adapter"/src/utility/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -o "$adapter_resources/MediaRemoteAdapter.framework/MediaRemoteAdapter"
codesign --force --sign - "$adapter_resources/MediaRemoteAdapter.framework"
codesign --force --sign - --identifier local.dialstudio.service "$app_dir/Contents/MacOS/ulanzid"
codesign --force --sign - --identifier local.dialstudio.app "$app_dir"
touch "$app_dir"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_dir"
print -r -- "$app_dir"
