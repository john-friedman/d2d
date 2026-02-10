import copy

def check_new_instruction_block(tag):
    """Return True if this tag ending should create a new instruction block."""
    return tag in {'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'br', 'table'}

def walk(node):
    yield ("start", node)
    for child in node.iter(include_text=True):
        yield from walk(child)
    yield ("end", node)


# text indent, padding,  padding left, margin, margin left, dispaly none, left indent
# skip empty instructions
# merge cells?
# tables - prob just expand

def parse_style(style, instruction_attributes):
    if not style:
        return False
    
    modified = False
    properties = style.split(';')
    
    for prop in properties:
        if ':' not in prop:
            continue
            
        key, value = prop.split(':', 1)
        key = key.strip().lower()
        value = value.strip().lower()
        
        if key == 'font-weight':
            instruction_attributes['font_weight'] = value
            modified = True
        elif key == 'font-style':
            if 'italic' in value:
                instruction_attributes['is_italic'] = True
                modified = True
        elif key == 'text-decoration':
            if 'underline' in value:
                instruction_attributes['is_underline'] = True
                modified = True
        elif key == 'text-align':
            if 'center' in value:
                instruction_attributes['is_text_center'] = True
                modified = True
        elif key == 'font-size':
            instruction_attributes['font_size'] = value
            modified = True
    
    return modified


def convert_html_to_instructions(root):
    instructions_list = []
    instructions_block = []
    
    starting_instruction_attribute = {
        'font_weight': None,
        'font_size': None,
        'href' : None,
        'header_tag': None,
        'is_italic': False,
        'is_underline': False,
        'is_text_center': False
    }

    style_stack = [(None, copy.deepcopy(starting_instruction_attribute))]

    for signal, node in walk(root):
        if signal == "start":
            if node.tag == '-text':
                instruction = {}
                instruction['text'] = node.text_content
                attrs = style_stack[-1][1]
                
                if attrs['font_weight']:
                    instruction['font_weight'] = attrs['font_weight']
                if attrs['font_size']:
                    instruction['font_size'] = attrs['font_size']
                if attrs['header_tag']:
                    instruction['header_tag'] = attrs['header_tag']
                if attrs['href']:
                    instruction['href'] = attrs['href']
                if attrs['is_italic']:
                    instruction['is_italic'] = True
                if attrs['is_underline']:
                    instruction['is_underline'] = True
                if attrs['is_text_center']:
                    instruction['is_text_center'] = True
                
                instructions_block.append(instruction)
            elif node.tag == 'img':
                instruction = {}
                if src := node.attributes.get('src'):
                    instruction['src'] = src
                if alt := node.attributes.get('alt'):
                    instruction['alt'] = alt
                instructions_block.append(instruction)
            else:
                current_attrs = copy.deepcopy(style_stack[-1][1])
                modified = False
                
                # Check tag-based styling
                if node.tag in ['b', 'strong']:
                    current_attrs['font_weight'] = node.tag
                    modified = True
                elif node.tag in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']:
                    current_attrs['header_tag'] = node.tag
                    modified = True
                elif node.tag in ["i", "em"]:
                    current_attrs['is_italic'] = True
                    modified = True
                elif node.tag in ["u", "ins"]:
                    current_attrs['is_underline'] = True
                    modified = True
                elif node.tag == 'a':
                    current_attrs['href'] = node.attributes.get('href', '')
                    modified = True
                
                # Check inline style
                if parse_style(node.attributes.get('style', ''), current_attrs):
                    modified = True
                
                if modified:
                    style_stack.append((node.mem_id, current_attrs))

        elif signal == "end":
            if len(style_stack) > 1 and style_stack[-1][0] == node.mem_id:
                style_stack.pop()
            
            if check_new_instruction_block(node.tag):
                instructions_list.append(instructions_block)
                instructions_block = []
    
    if instructions_block:
        instructions_list.append(instructions_block)
            
    with open('test.txt', 'w') as f:
        for instruction_block in instructions_list:
            f.write(str(instruction_block))
            f.write('\n')
    
    return instructions_list