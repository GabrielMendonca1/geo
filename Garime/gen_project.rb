#!/usr/bin/env ruby
require "xcodeproj"
require "fileutils"

root = File.dirname(File.expand_path(__FILE__))
proj_path = File.join(root, "Garime.xcodeproj")
FileUtils.rm_rf(proj_path)

project = Xcodeproj::Project.new(proj_path)

target = project.new_target(:application, "Garime", :ios, "17.0")

common = {
  "PRODUCT_BUNDLE_IDENTIFIER" => "com.gabrielmendonca.garime",
  "PRODUCT_NAME" => "$(TARGET_NAME)",
  "SDKROOT" => "iphoneos",
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
  "TARGETED_DEVICE_FAMILY" => "1",
  "SWIFT_VERSION" => "5.9",
  "GENERATE_INFOPLIST_FILE" => "YES",
  "INFOPLIST_KEY_CFBundleDisplayName" => "garime",
  "INFOPLIST_KEY_UILaunchScreen_Generation" => "YES",
  "INFOPLIST_KEY_UIApplicationSceneManifest_Generation" => "YES",
  "INFOPLIST_KEY_UISupportedInterfaceOrientations" => "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
  "CODE_SIGN_STYLE" => "Automatic",
  "DEVELOPMENT_TEAM" => "6RRNRWCXSD",
  "ENABLE_PREVIEWS" => "YES",
  "INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription" => "Geo shows your calendar events in the day agenda.",
  "INFOPLIST_KEY_NSRemindersFullAccessUsageDescription" => "Geo reads and completes the reminders your Mac mirrors here.",
  "INFOPLIST_KEY_NSMicrophoneUsageDescription" => "O garime usa o microfone para ditar mensagens ao agente.",
  "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription" => "A fala vira texto no próprio iPhone para você revisar antes de enviar.",
  "INFOPLIST_FILE" => "Garime/Info.plist",
  "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
}

target.build_configurations.each do |config|
  config.build_settings.merge!(common)
end

test_target = project.new_target(:unit_test_bundle, "GarimeTests", :ios, "17.0")
test_target.add_dependency(target)
test_target.build_configurations.each do |config|
  config.build_settings.merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.gabrielmendonca.garime.tests",
    "SWIFT_VERSION" => "5.9",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "TARGETED_DEVICE_FAMILY" => "1",
    "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/Garime.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Garime",
    "BUNDLE_LOADER" => "$(TEST_HOST)",
  )
end

ui_test_target = project.new_target(:ui_test_bundle, "GarimeUITests", :ios, "17.0")
ui_test_target.add_dependency(target)
ui_test_target.build_configurations.each do |config|
  config.build_settings.merge!(
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.gabrielmendonca.garime.uitests",
    "SWIFT_VERSION" => "5.9",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "TARGETED_DEVICE_FAMILY" => "1",
    "TEST_TARGET_NAME" => "Garime",
  )
end

group = project.main_group.new_group("Garime", "Garime")
src_root = File.join(root, "Garime")
Dir.glob(File.join(src_root, "**", "*.swift")).sort.each do |path|
  rel = path.sub(src_root + "/", "")
  ref = group.new_reference(rel)
  target.add_file_references([ref])
end

assets_ref = group.new_reference("Assets.xcassets")
target.add_resources([assets_ref])

tests_group = project.main_group.new_group("GarimeTests", "GarimeTests")
tests_root = File.join(root, "GarimeTests")
Dir.glob(File.join(tests_root, "**", "*.swift")).sort.each do |path|
  rel = path.sub(tests_root + "/", "")
  ref = tests_group.new_reference(rel)
  test_target.add_file_references([ref])
end

ui_tests_group = project.main_group.new_group("GarimeUITests", "GarimeUITests")
ui_tests_root = File.join(root, "GarimeUITests")
Dir.glob(File.join(ui_tests_root, "**", "*.swift")).sort.each do |path|
  rel = path.sub(ui_tests_root + "/", "")
  ref = ui_tests_group.new_reference(rel)
  ui_test_target.add_file_references([ref])
end

local_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
local_ref.relative_path = "../GeoCore"
project.root_object.package_references << local_ref

product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product_dep.package = local_ref
product_dep.product_name = "GeoCore"
target.package_product_dependencies << product_dep

build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product_dep
target.frameworks_build_phase.files << build_file

swiftterm_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
swiftterm_ref.repositoryURL = "https://github.com/migueldeicaza/SwiftTerm"
swiftterm_ref.requirement = { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.13.0" }
project.root_object.package_references << swiftterm_ref

swiftterm_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
swiftterm_dep.package = swiftterm_ref
swiftterm_dep.product_name = "SwiftTerm"
target.package_product_dependencies << swiftterm_dep

swiftterm_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
swiftterm_build_file.product_ref = swiftterm_dep
target.frameworks_build_phase.files << swiftterm_build_file

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(test_target)
scheme.add_test_target(ui_test_target)
scheme.set_launch_target(target) if scheme.respond_to?(:set_launch_target)
scheme.save_as(proj_path, "Garime", true)

puts "Generated #{proj_path}"
