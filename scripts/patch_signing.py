import sys
import os
import re

path = sys.argv[1]
if not os.path.exists(path):
    print(f"File not found: {path}")
    sys.exit(1)

with open(path) as f:
    original = f.read()

if 'keystoreProperties' in original:
    print("Signing already configured")
    sys.exit(0)

header = (
    'import java.util.Properties\n'
    'import java.io.FileInputStream\n\n'
    'val keystorePropertiesFile = rootProject.file("key.properties")\n'
    'val keystoreProperties = Properties()\n'
    'if (keystorePropertiesFile.exists()) {\n'
    '    keystoreProperties.load(FileInputStream(keystorePropertiesFile))\n'
    '}\n\n'
)

signing_config = (
    '\n    signingConfigs {\n'
    '        create("audiolens") {\n'
    '            keyAlias = keystoreProperties["keyAlias"] as String?\n'
    '            keyPassword = keystoreProperties["keyPassword"] as String?\n'
    '            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }\n'
    '            storePassword = keystoreProperties["storePassword"] as String?\n'
    '        }\n'
    '    }\n'
)

result = header + original

# Insert signingConfigs inside android {}
result = re.sub(r'(android\s*\{)', r'\1' + signing_config, result, count=1)

# Replace the entire buildTypes block with one that has both debug and release
new_build_types = (
    'buildTypes {\n'
    '        debug {\n'
    '            signingConfig = signingConfigs.getByName("audiolens")\n'
    '        }\n'
    '        release {\n'
    '            signingConfig = signingConfigs.getByName("audiolens")\n'
    '        }\n'
    '    }'
)

# Match buildTypes { ... } where ... may contain nested braces
def replace_build_types(text, replacement):
    start = text.find('buildTypes')
    if start == -1:
        return text
    # Find the matching closing brace
    depth = 0
    i = text.index('{', start)
    while i < len(text):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[:start] + replacement + text[i+1:]
        i += 1
    return text

result = replace_build_types(result, new_build_types)

with open(path, 'w') as f:
    f.write(result)

print("Signing configured for debug AND release buildTypes")
print(result)
