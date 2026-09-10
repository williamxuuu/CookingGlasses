#!/usr/bin/env ruby
# Optional regeneration tool; the generated project is checked in.
require 'xcodeproj'
root = File.expand_path('..', __dir__)
project_path = File.join(root, 'CookingGlasses.xcodeproj')
project = Xcodeproj::Project.new(project_path)
app = project.new_target(:application, 'CookingGlasses', :ios, '17.2')
app.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.cookingglasses.sous',
    'PRODUCT_NAME' => 'Sous',
    'SWIFT_VERSION' => '5.0',
    'INFOPLIST_FILE' => 'iOS/App/Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'TARGETED_DEVICE_FAMILY' => '1',
    'CODE_SIGN_STYLE' => 'Automatic',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
    'SWIFT_STRICT_CONCURRENCY' => 'targeted'
  })
end
sources = project.main_group.new_group('iOS')
Dir.glob(File.join(root, 'iOS/**/*.swift')).sort.each do |path|
  reference = sources.new_file(path.delete_prefix(root + '/'))
  app.source_build_phase.add_file_reference(reference)
end
core = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
core.relative_path = '.'
project.root_object.package_references << core
dat = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
dat.repositoryURL = 'https://github.com/facebook/meta-wearables-dat-ios'
dat.requirement = { 'kind' => 'exactVersion', 'version' => '0.9.0' }
project.root_object.package_references << dat
[[core, 'CookingCore'], [dat, 'MWDATCore'], [dat, 'MWDATCamera'], [dat, 'MWDATDisplay']].each do |package, name|
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = package
  product.product_name = name
  app.package_product_dependencies << product
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  app.frameworks_build_phase.files << build_file
end
ui_tests = project.new_target(:ui_test_bundle, 'CookingGlassesUITests', :ios, '17.2')
ui_tests.add_dependency(app)
ui_tests.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.cookingglasses.sous.uitests',
    'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES',
    'TEST_TARGET_NAME' => 'CookingGlasses', 'CODE_SIGN_STYLE' => 'Automatic'
  })
end
test_group = project.main_group.new_group('iOSUITests')
Dir.glob(File.join(root, 'iOSUITests/*.swift')).sort.each do |path|
  ui_tests.source_build_phase.add_file_reference(test_group.new_file(path.delete_prefix(root + '/')))
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(ui_tests)
scheme.save_as(project_path, 'CookingGlasses', true)
puts "Generated #{project_path}"
