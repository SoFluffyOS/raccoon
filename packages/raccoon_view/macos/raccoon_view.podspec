#
# The macOS plugin for CocoaPods hosts; raccoon_view/Package.swift serves
# Swift Package Manager hosts from the same sources.
#
Pod::Spec.new do |s|
  s.name             = 'raccoon_view'
  s.version          = '0.0.1'
  s.summary          = 'Shows an app hosted by the Raccoon runtime.'
  s.description      = <<-DESC
The host side of Raccoon's GPU buffers on macOS: a Flutter texture fed from
the runner's GPU socket, so frames show without a copy.
                       DESC
  s.homepage         = 'https://github.com/SoFluffyOS/raccoon_view'
  s.license          = { :type => 'BSD', :file => '../LICENSE' }
  s.author           = { 'The Raccoon Authors' => 'https://github.com/SoFluffyOS' }
  s.source           = { :path => '.' }
  s.source_files     = 'raccoon_view/Sources/raccoon_view/**/*.{h,mm}'
  s.public_header_files = 'raccoon_view/Sources/raccoon_view/include/**/*.h'
  s.dependency 'FlutterMacOS'
  s.frameworks       = 'CoreVideo', 'IOSurface'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
end
