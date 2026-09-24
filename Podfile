# HearMeOut Podfile — Agora SDKs via CocoaPods.
#
# WHY NOT SPM: Agora's RTC (4.5+) and Signaling/RTM (2.2+) SPM packages both
# embed a binary target named `aosl`, and SPM rejects duplicate target names
# across the package graph at *resolve* time. The pairing below sidesteps it:
# RTC 4.4.0 predates the bundled-aosl change (4.5.0+), so only RTM ships
# aosl and there is nothing to collide with. Pinned exact — do NOT float
# RTC past 4.4.x without re-checking for aosl.
# GRDB + supabase-swift stay on SPM (no conflicts there).

platform :ios, '17.0'

# aosl dedup (per Agora's official FAQ for RTM 2.x + RTC co-integration):
# both pods vendor aosl.xcframework and the target rejects duplicate names.
# RTM 2.2.6 ships aosl 1.2.13, RTC 4.4.0 ships 1.1.10 — delete the LOWER one
# (RTC's) after download, before integration. The surviving 1.2.13 serves
# both SDKs. Re-verify versions if either pod is ever bumped.
pre_install do |installer|
  rtc_aosl = File.join(installer.sandbox.root, 'AgoraRtcEngine_iOS', 'aosl.xcframework')
  if File.exist?(rtc_aosl)
    puts 'Deleting lower-version aosl.xcframework from AgoraRtcEngine_iOS (keeping RTM 1.2.13)'
    FileUtils.rm_rf(rtc_aosl)
  end
end

target 'HearMeOut' do
  use_frameworks!

  pod 'AgoraRtcEngine_iOS', '4.4.0'
  pod 'AgoraRtm_iOS', '2.2.6'
end

post_install do |installer|
  # Keep the app's Config.xcconfig (SUPABASE_URL etc.) visible after
  # CocoaPods rewires the target's base configuration to the Pods xcconfigs.
  %w[Debug Release].each do |config|
    xcconfig = "Pods/Target Support Files/Pods-HearMeOut/Pods-HearMeOut.#{config.downcase}.xcconfig"
    next unless File.exist?(xcconfig)

    include_line = '#include "../../../Config.xcconfig"'
    content = File.read(xcconfig)
    unless content.include?(include_line)
      File.open(xcconfig, 'a') { |f| f.puts("\n#{include_line}") }
    end
  end

  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    end
  end
end
