import sys
import os
import re

path = sys.argv[1]
if not os.path.exists(path):
    print(f"File not found: {path}")
    sys.exit(1)

with open(path) as f:
    original = f.read()

print("=== Original build.gradle.kts ===")
print(original)
print("=== End ===")

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

signing_config = '''
    signingConfigs {
        create("audiolens") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }
'''

result = header + original

# Insert signingConfigs after 'android {' (any whitespace variant)
result = re.sub(
    r'(android\s*\{)',
    r'\1' + signing_config,
    result,
    count=1
)

# Apply signing to ALL buildTypes using regex
# Replace any signingConfig = signingConfigs.getByName("debug")
result = re.sub(
    r'signingConfig\s*=\s*signingConfigs\.getByName\(["\']debug["\']\)',
    'signingConfig = signingConfigs.getByName("audiolens")',
    result
)

# Add signingConfig to debug buildType if not present
if 'signingConfig = signingConfigs.getByName("audiolens")' not in result:
    # Find debug buildType and add signing
    result = re.sub(
        r'(debug\s*\{)',
        r'\1\n            signingConfig = signingConfigs.getByName("audiolens")',
        result
    )

with open(path, 'w') as f:
    f.write(result)

print("Signing configured successfully")
print("=== Result ===")
print(result)
