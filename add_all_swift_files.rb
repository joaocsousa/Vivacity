require 'xcodeproj'
require 'find'

project_path = 'Vivacity.xcodeproj'
project = Xcodeproj::Project.open(project_path)
main_target = project.targets.find { |t| t.name == 'Vivacity' }

project_dir = 'Vivacity'

Find.find(project_dir) do |path|
  if path =~ /.*\.swift$/
    # Skip any files in test folders, we only want the main app files
    next if path.include?('VivacityTests') || path.include?('VivacityUITests')

    # Check if the file is already in the project
    rel_path = path.sub("#{project_dir}/", '')
    
    file_ref = project.files.find { |f| f.real_path.to_s == path || f.path == rel_path || f.path == path.split('/').last }
    
    if file_ref.nil?
      # We need to find or create the group
      dirname = File.dirname(rel_path)
      group = project.main_group.find_subpath(File.join('Vivacity', dirname), true)
      group.set_source_tree('<group>')
      file_ref = group.new_file(File.basename(path))
      puts "Added new file reference for #{path}"
    end

    # Check if this file is in the build phase of the main target
    if !main_target.source_build_phase.files_references.include?(file_ref)
      main_target.add_file_references([file_ref])
      puts "Added #{path} to main target build phase"
    end
  end
end

project.save
puts "Project saved."
