import os
import glob

# Files to update
files = glob.glob('lib/**/*.dart', recursive=True)

replacements = {
    '0xFF09090B': '0xFFFDFDFD', # Main background (off-white, very slight warm tint)
    '0xFF18181B': '0xFFF4F4F5', # Surface / TextField background (light zinc)
    '0xFF27272A': '0xFFE4E4E7', # Borders / Secondary containers (zinc-200)
    # Brightness and Text Theme
    'Brightness.dark': 'Brightness.light',
    'ThemeData.dark()': 'ThemeData.light()',
}

for filepath in files:
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    new_content = content
    for old, new in replacements.items():
        new_content = new_content.replace(old, new)
        
    # Also adjust text colors in ChatScreen to be visible on the new light backgrounds
    if 'chat_screen.dart' in filepath:
        # User message is Indigo (white text is fine). Other person message is Surface (0xFFF4F4F5), so white text is invisible!
        # Need to fix the hardcoded Colors.white for text in chat bubbles.
        new_content = new_content.replace('color: Colors.white,', 'color: msg.isMe ? Colors.white : Colors.black87,')
        
    if new_content != content:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"Updated {filepath}")
