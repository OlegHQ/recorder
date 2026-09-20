#!/usr/bin/env ruby
# Exercise the real installer in a temporary filesystem with privacy/quit/signing
# commands stubbed. Never modify /Applications, Keychain, or real privacy grants.
require 'tmpdir'
require 'fileutils'
require 'open3'

installer = File.read(File.join(__dir__, 'install-app.sh'))
%w[success signature quit replace restore reset legacy].each do |scenario|
  Dir.mktmpdir('recorder-install-test-') do |dir|
    apps = File.join(dir, 'Applications')
    bin = File.join(dir, 'bin')
    FileUtils.mkdir_p([bin, "#{apps}/Recorder.app", "#{dir}/build/Recorder.app"])
    File.write("#{apps}/Recorder.app/version", 'old')
    File.write("#{dir}/build/Recorder.app/version", 'new')
    runner = File.join(dir, 'install.sh')
    File.write(runner, installer.gsub('/Applications', apps).sub(
      '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
      "#{bin}/lsregister"))
    stub = <<~'RUBY'
      #!/usr/bin/ruby
      require 'fileutils'
      name = File.basename($0)
      File.open(ENV.fetch('CALLS'), 'a') { |f| f.puts(([name] + ARGV).join('|')) }
      scenario = ENV.fetch('SCENARIO')
      case name
      when 'codesign'
        exit 1 if scenario == 'signature'
      when 'osascript'
        STDIN.read
        exit 1 if scenario == 'quit'
      when 'mv'
        exit 1 if %w[replace restore].include?(scenario) && ARGV[0].include?('.Recorder-install.') && ARGV[0].end_with?('/Recorder.app')
        exit 1 if scenario == 'restore' && ARGV[0].end_with?('/Previous.app')
        FileUtils.mv(ARGV[0], ARGV[1])
      when 'tccutil'
        exit 1 if scenario == 'reset' && ARGV.last == 'space.microapps.recorder'
        exit 1 if scenario == 'legacy' && ARGV.last == 'sh.nexo.recorder'
      end
    RUBY
    %w[codesign osascript mv tccutil lsregister].each do |name|
      path = File.join(bin, name)
      File.write(path, stub)
      File.chmod(0755, path)
    end
    env = { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'CALLS' => "#{dir}/calls", 'SCENARIO' => scenario }
    output, status = Open3.capture2e(env, 'sh', runner, chdir: dir)
    expected_success = %w[success legacy].include?(scenario)
    abort "#{scenario}: unexpected exit\n#{output}" unless status.success? == expected_success
    expected_version = %w[signature quit replace restore].include?(scenario) ? 'old' : 'new'
    version_file = scenario == 'restore' ? Dir.glob("#{apps}/.Recorder-install.*/Previous.app/version").first : "#{apps}/Recorder.app/version"
    abort "#{scenario}: installed app lost" unless version_file && File.read(version_file) == expected_version
    calls = File.readlines("#{dir}/calls", chomp: true)
    resets = calls.select { |line| line.start_with?('tccutil|') }
    expected_resets = expected_version == 'old' ? [] :
      %w[ScreenCapture Accessibility Camera Microphone].flat_map { |service|
        %w[space.microapps.recorder sh.nexo.recorder].map { |id| "tccutil|reset|#{service}|#{id}" }
      }
    abort "#{scenario}: wrong reset scope #{resets}" unless resets == expected_resets
    abort 'Missing signing requirement' unless calls.first.include?('certificate leaf[subject.CN] = "Recorder Dev"')
    puts "install #{scenario}: OK"
  end
end

# Test first-time certificate generation with macOS's bundled LibreSSL, but stub
# Keychain access so the generated identity is only validated, never imported.
Dir.mktmpdir('recorder-cert-test-') do |dir|
  security = File.join(dir, 'security')
  File.write(security, <<~'SH')
    #!/bin/sh
    case "$1" in
      find-identity) exit 0 ;;
      import) exec /usr/bin/openssl pkcs12 -in "$2" -passin pass:recorder -noout ;;
      *) exit 1 ;;
    esac
  SH
  File.chmod(0755, security)
  output, status = Open3.capture2e({ 'PATH' => "#{dir}:#{ENV.fetch('PATH')}" },
                                  'make', 'cert', chdir: File.expand_path('..', __dir__))
  abort "Certificate generation failed: #{output}" unless status.success? && output.include?('Created identity: Recorder Dev')
  puts 'certificate generation without Keychain mutation: OK'
end
