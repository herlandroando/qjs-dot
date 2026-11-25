Pod::Spec.new do |s|
  s.name             = 'qjs_dot'
  s.version          = '0.1.0'
  s.summary          = 'Lightweight sandboxed QuickJS-ng FFI runtime for Flutter.'
  s.description      = <<-DESC
Lightweight, sandboxed QuickJS-ng FFI runtime for Flutter with Worker Isolate execution, Promises, timers, fetch, Web APIs, and ES Modules.
                       DESC
  s.homepage         = 'https://github.com/qjs-dot/qjs-dot'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'qjs-dot contributors' => 'noreply@example.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_CFLAGS' => '-std=gnu11 -funsigned-char -D_GNU_SOURCE -DQUICKJS_NG_BUILD -DQJS_DOT_BUILD -I"$(PODS_TARGET_SRCROOT)/../src" -I"$(PODS_TARGET_SRCROOT)/../src/quickjs-ng"'
  }
  s.swift_version = '5.0'
end
