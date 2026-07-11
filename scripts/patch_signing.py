import sys
import os

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

signing = (
    '\n    signingConfigs {\n'
    '        create("release") {\n'
    '            keyAlias = keystoreProperties["keyAlias"] as String?\n'
    '            keyPassword = keystoreProperties["keyPassword"] as String?\n'
    '            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }\n'
    '            storePassword = keystoreProperties["storePassword"] as String?\n'
    '        }\n'
    '    }\n'
)

result = header + original
result = result.replace('android {', 'android {' + signing, 1)
result = result.replace(
    'signingConfig = signingConfigs.getByName("debug")',
    'signingConfig = signingConfigs.getByName("release")'
)

with open(path, 'w') as f:
    f.write(result)

print(f"Signing configured in {path}")
