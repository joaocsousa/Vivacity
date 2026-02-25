import uuid
import re
import sys

def gen_uuid():
    return uuid.uuid4().hex[:24].upper()

pbx_path = "Vivacity.xcodeproj/project.pbxproj"
try:
    with open(pbx_path, "r") as f:
        content = f.read()
except FileNotFoundError:
    print("Error: project.pbxproj not found")
    sys.exit(1)

if "PermissionService.swift" in content:
    print("Files already added")
    sys.exit(0)

# Generate unique IDs for each new file
perm_svc_file_ref = gen_uuid()
perm_svc_build_file = gen_uuid()
perm_denied_file_ref = gen_uuid()
perm_denied_build_file = gen_uuid()

# 1. Add PBXFileReference entries
file_ref_section_end = content.find("/* End PBXFileReference section */")

new_file_refs = f"""		{perm_svc_file_ref} /* PermissionService.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PermissionService.swift; sourceTree = "<group>"; }};
		{perm_denied_file_ref} /* PermissionDeniedView.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PermissionDeniedView.swift; sourceTree = "<group>"; }};
"""

content = content[:file_ref_section_end] + new_file_refs + content[file_ref_section_end:]

# 2. Add PBXBuildFile entries
build_file_section_end = content.find("/* End PBXBuildFile section */")

new_build_files = f"""		{perm_svc_build_file} /* PermissionService.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {perm_svc_file_ref} /* PermissionService.swift */; }};
		{perm_denied_build_file} /* PermissionDeniedView.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {perm_denied_file_ref} /* PermissionDeniedView.swift */; }};
"""

content = content[:build_file_section_end] + new_build_files + content[build_file_section_end:]

# 3. Add to Services group
services_pattern = re.search(r'(/\* Services \*/ = \{[^{}]*children = \([^)]*)', content)
if services_pattern:
    insert_pos = services_pattern.end()
    content = content[:insert_pos] + f"\n				{perm_svc_file_ref} /* PermissionService.swift */," + content[insert_pos:]
    print("Added PermissionService.swift to Services group")
else:
    print("WARNING: Could not find Services group")

# 4. Add to FileScan group
filescan_pattern = re.search(r'(/\* FileScan \*/ = \{[^{}]*children = \([^)]*)', content)
if filescan_pattern:
    insert_pos = filescan_pattern.end()
    content = content[:insert_pos] + f"\n				{perm_denied_file_ref} /* PermissionDeniedView.swift */," + content[insert_pos:]
    print("Added PermissionDeniedView.swift to FileScan group")
else:
    print("WARNING: Could not find FileScan group")

# 5. Add to Sources build phase
sources_pattern = re.search(r'(/\* Sources \*/ = \{[^{}]*files = \([^)]*)', content)
if sources_pattern:
    insert_pos = sources_pattern.end()
    new_sources = f"\n				{perm_svc_build_file} /* PermissionService.swift in Sources */,\n				{perm_denied_build_file} /* PermissionDeniedView.swift in Sources */,"
    content = content[:insert_pos] + new_sources + content[insert_pos:]
    print("Added both files to Sources build phase")
else:
    print("WARNING: Could not find Sources build phase")

with open(pbx_path, "w") as f:
    f.write(content)

print("Project updated successfully")
