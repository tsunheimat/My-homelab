import os
from PIL import Image, ImageDraw, ImageFont
import colorsys

def adjust_hue(r, g, b, hue_shift):
    # normalize
    r_n, g_n, b_n = r / 255.0, g / 255.0, b / 255.0
    h, s, v = colorsys.rgb_to_hsv(r_n, g_n, b_n)
    h = (h + hue_shift) % 1.0
    r_n, g_n, b_n = colorsys.hsv_to_rgb(h, s, v)
    return int(r_n * 255), int(g_n * 255), int(b_n * 255)

def create_chrome_icon(number, hue_shift, output_path):
    size = 256
    image = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # Base colors
    color_red = (219, 68, 55)
    color_yellow = (244, 180, 0)
    color_green = (15, 157, 88)
    color_blue = (66, 133, 244)

    # Shift colors for the outer ring only
    color_red = adjust_hue(*color_red, hue_shift)
    color_yellow = adjust_hue(*color_yellow, hue_shift)
    color_green = adjust_hue(*color_green, hue_shift)
    # The center color_blue remains unshifted

    cx, cy = size // 2, size // 2
    r_outer = 120
    r_white = 58
    r_inner = 50

    bbox_outer = (cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer)
    bbox_white = (cx - r_white, cy - r_white, cx + r_white, cy + r_white)
    bbox_inner = (cx - r_inner, cy - r_inner, cx + r_inner, cy + r_inner)

    # Top red (PIL angles are clockwise from positive x-axis. 0 is right, 90 is bottom)
    # So top is 270. From 210 to 330.
    draw.pieslice(bbox_outer, 210, 330, fill=color_red)
    # Right yellow: 330 to 90
    draw.pieslice(bbox_outer, 330, 90, fill=color_yellow)
    # Left green: 90 to 210
    draw.pieslice(bbox_outer, 90, 210, fill=color_green)

    # White circle
    draw.ellipse(bbox_white, fill=(255, 255, 255))

    # Inner blue (shifted)
    draw.ellipse(bbox_inner, fill=color_blue)

    # Text
    try:
        font = ImageFont.truetype("arialbd.ttf", 60)
    except IOError:
        font = ImageFont.load_default()

    text = str(number)
    # Get bounding box using textbbox
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    
    text_x = cx - text_w // 2
    # Adjust y somewhat due to how textbbox height works
    text_y = cy - text_h // 2 - 8 

    # Draw text shadow / border for visibility
    shadow_color = (0, 0, 0, 128)
    draw.text((text_x+2, text_y+2), text, font=font, fill=shadow_color)
    draw.text((text_x, text_y), text, font=font, fill=(255, 255, 255))

    image.save(output_path, format="ICO", sizes=[(256, 256), (128, 128), (64, 64), (32, 32)])

if __name__ == "__main__":
    icons_dir = "icons"
    os.makedirs(icons_dir, exist_ok=True)
    
    for i in range(1, 21):
        # Shift hue uniformly across the color wheel
        # For 20 icons, it's i * (1.0 / 20)
        hue_shift = i * (1.0 / 20.0)
        output_path = os.path.join(icons_dir, f"icon_{i}.ico")
        create_chrome_icon(i, hue_shift, output_path)
    
    print(f"Generated 20 icons in {os.path.abspath(icons_dir)} directory.")
