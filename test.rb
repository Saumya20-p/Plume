require 'xcodeproj'
p = Xcodeproj::Project.open('Plume/Plume.xcodeproj')
scheme_path = Xcodeproj::XCScheme.shared_data_dir(p.path) + 'Plume.xcscheme'
scheme = Xcodeproj::XCScheme.new(scheme_path)
puts scheme.launch_action.xml_element.to_s
