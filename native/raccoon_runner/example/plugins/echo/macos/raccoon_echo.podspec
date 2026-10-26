Pod::Spec.new do |s|
  s.name             = 'raccoon_echo'
  s.version          = '0.1.0'
  s.summary          = 'The runner\'s test plugin: echo from the main queue, and a texture.'
  s.homepage         = 'https://github.com/SoFluffyOS/raccoon'
  s.license          = { :type => 'BSD', :file => '../../../../LICENSE' }
  s.author           = 'Simon Pham'
  s.source           = { :path => '.' }
  s.source_files     = 'raccoon_echo/Sources/raccoon_echo/**/*.{h,m}'
  s.public_header_files = 'raccoon_echo/Sources/raccoon_echo/include/**/*.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
