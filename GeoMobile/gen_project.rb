#!/usr/bin/env ruby
require "xcodeproj"
require "fileutils"

root = File.dirname(File.expand_path(__FILE__))
proj_path = File.join(root, "GeoMobile.xcodeproj")
FileUtils.rm_rf(proj_path)

project = Xcodeproj::Project.new(proj_path)

target = project.new_target(:application, "GeoMobile", :ios, "17.0")

common = {
  "PRODUCT_BUNDLE_IDENTIFIER" => "com.gabrielmendonca.geomobile",
  "PRODUCT_NAME" => "$(TARGET_NAME)",
  "SDKROOT" => "iphoneos",
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
  "TARGETED_DEVICE_FAMILY" => "1",
  "SWIFT_VERSION" => "5.9",
  "GENERATE_INFOPLIST_FILE" => "YES",
  "INFOPLIST_KEY_UILaunchScreen_Generation" => "YES",
  "INFOPLIST_KEY_UIApplicationSceneManifest_Generation" => "YES",
  "INFOPLIST_KEY_UISupportedInterfaceOrientations" => "UIInterfaceOrientationPortrait",
  "CODE_SIGN_STYLE" => "Automatic",
  "DEVELOPMENT_TEAM" => "",
  "ENABLE_PREVIEWS" => "YES",
  "INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription" => "Geo shows your calendar events in the day agenda.",
  "INFOPLIST_KEY_NSRemindersFullAccessUsageDescription" => "Geo reads and completes the reminders your Mac mirrors here.",
}

target.build_configurations.each do |config|
  config.build_settings.merge!(common)
end

group = project.main_group.new_group("GeoMobile", "GeoMobile")
src_root = File.join(root, "GeoMobile")
Dir.glob(File.join(src_root, "**", "*.swift")).sort.each do |path|
  rel = path.sub(src_root + "/", "")
  ref = group.new_reference(rel)
  target.add_file_references([ref])
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

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target) if scheme.respond_to?(:set_launch_target)
scheme.save_as(proj_path, "GeoMobile", true)

puts "Generated #{proj_path}"
