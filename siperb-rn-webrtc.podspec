require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name                = package['name']
  s.version             = package['version']
  s.summary             = package['description']
  s.homepage            = 'https://github.com/Siperb/siperb-rn-webrtc'
  s.license             = package['license']
  s.author              = 'https://github.com/Siperb/siperb-rn-webrtc/graphs/contributors'
  s.source              = { :git => 'git@github.com:Siperb/siperb-rn-webrtc.git', :tag => 'release #{s.version}' }
  s.requires_arc        = true

  s.platforms           = { :ios => '12.0', :osx => '10.13', :tvos => '16.0' }

  s.preserve_paths      = 'ios/**/*'
  s.source_files        = 'ios/**/*.{h,m}'
  s.libraries           = 'c', 'sqlite3', 'stdc++'
  # CoreImage / CoreMedia / Metal are the call VIDEO recorder's (CallVideoRecorder.m): the
  # compositor renders through a CIContext backed by a Metal device where there is one, and
  # the mixed PCM reaches AVAssetWriter as a CMSampleBuffer. Listed EXPLICITLY rather than
  # left to clang's module autolinking, which works right up until a target has modules
  # disabled — and the failure then is at link time, which reading the source never reveals.
  s.framework           = 'AudioToolbox','AVFoundation', 'CoreAudio', 'CoreGraphics', 'CoreImage', 'CoreMedia', 'CoreVideo', 'GLKit', 'Metal', 'VideoToolbox'
  s.dependency          'React-Core'
  s.dependency          'WebRTC-SDK', '125.6422.07'
end
