import os
import glob
import re

files = glob.glob('lib/**/*.dart', recursive=True)

for filepath in files:
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    new_content = content
    
    # 1. onboarding_screen.dart
    if 'onboarding_screen.dart' in filepath:
        new_content = new_content.replace('color: Colors.white,', '')
        new_content = new_content.replace("color: Colors.grey[400]", "color: Colors.black54")
        new_content = new_content.replace("color: Colors.grey[500]", "color: Colors.black54")
        new_content = new_content.replace("style: TextStyle(color: Colors.white)", "style: TextStyle(color: Colors.black87)")
        
    # 2. discover_screen.dart
    if 'discover_screen.dart' in filepath:
        new_content = new_content.replace('color: Colors.white', 'color: Colors.black87')
        
    # 3. chat_list_screen.dart
    if 'chat_list_screen.dart' in filepath:
        new_content = new_content.replace('color: Colors.white', 'color: Colors.black87')
        new_content = new_content.replace("color: Colors.grey[400]", "color: Colors.black54")
        
    # 4. chat_screen.dart
    if 'chat_screen.dart' in filepath:
        # We already patched the message color, but let's check subtitle
        new_content = new_content.replace("color: Colors.grey[400]", "color: Colors.black54")
        
    # 5. profile_screen.dart
    if 'profile_screen.dart' in filepath:
        new_content = new_content.replace("color: Colors.grey[400]", "color: Colors.black54")
        new_content = new_content.replace("color: Colors.grey[500]", "color: Colors.black54")
        # Keep Colors.white for the QR code background and button foregrounds
        
    if new_content != content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"Patched text colors in {filepath}")
