import copy


def check_new_instruction_block(tag):
    """Return True if this tag ending should create a new instruction block."""
    return tag in {'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'br'}


def walk(node):
    yield ("start", node)
    for child in node.iter(include_text=True):
        yield from walk(child)
    yield ("end", node)


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
        elif key == 'display':
            if 'none' in value:
                instruction_attributes['display_none'] = True
                modified = True
    
    return modified


def convert_html_to_instructions(root):
    instructions_list = []
    instructions_block = []
    
    starting_instruction_attribute = {
        'font_weight': None,
        'font_size': None,
        'href': None,
        'header_tag': None,
        'is_italic': False,
        'is_underline': False,
        'is_text_center': False,
        'display_none': False
    }

    style_stack = [(None, copy.deepcopy(starting_instruction_attribute))]
    
    # Table tracking
    in_table = False
    in_cell = False
    table_data = []
    table_spans = []
    current_cell_instructions = []
    current_rowspan = 1
    current_colspan = 1
    
    # Display:none tracking
    skip_subtree = False
    skip_mem_id = None

    for signal, node in walk(root):
        if signal == "start":
            # Skip if in display:none subtree
            if skip_subtree:
                continue
            
            # Table structure
            if node.tag == 'table':
                in_table = True
                table_data = []
                table_spans = []
                continue
            elif node.tag == 'tr' and in_table:
                table_data.append([])
                table_spans.append([])
                continue
            elif node.tag in ['td', 'th'] and in_table:
                in_cell = True
                current_cell_instructions = []
                current_rowspan = int(node.attributes.get('rowspan', 1))
                current_colspan = int(node.attributes.get('colspan', 1))
                # Don't continue - we still want to process styling
            
            # Text nodes
            if node.tag == '-text':
                
                # only add non empty text
                if node.text_content.strip() == '':
                    continue

                instruction = {'text': node.text_content}
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
                
                # Add to cell or block
                if in_cell:
                    current_cell_instructions.append(instruction)
                else:
                    instructions_block.append(instruction)
                    
            # Image nodes
            elif node.tag == 'img':
                instruction = {}
                if src := node.attributes.get('src'):
                    instruction['src'] = src
                if alt := node.attributes.get('alt'):
                    instruction['alt'] = alt
                
                attrs = style_stack[-1][1]
                if attrs['font_weight']:
                    instruction['font_weight'] = attrs['font_weight']
                if attrs['font_size']:
                    instruction['font_size'] = attrs['font_size']
                
                # Add to cell or block
                if in_cell:
                    current_cell_instructions.append(instruction)
                else:
                    instructions_block.append(instruction)
                    
            # Other tags - check for styling
            else:
                current_attrs = copy.deepcopy(style_stack[-1][1])
                modified = False
                
                # Tag-based styling
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
                
                # Inline style
                if parse_style(node.attributes.get('style', ''), current_attrs):
                    modified = True
                
                # Check for display:none
                if current_attrs['display_none']:
                    skip_subtree = True
                    skip_mem_id = node.mem_id
                
                if modified:
                    style_stack.append((node.mem_id, current_attrs))

        elif signal == "end":
            # Handle display:none exit
            if skip_subtree and node.mem_id == skip_mem_id:
                skip_subtree = False
                skip_mem_id = None
            
            # Pop style stack
            if len(style_stack) > 1 and style_stack[-1][0] == node.mem_id:
                style_stack.pop()
            
            # Table structure
            if node.tag == 'table':
                instructions_block.append({
                    'table_data': table_data,
                    'table_spans': table_spans
                })
                in_table = False
                table_data = []
                table_spans = []
                continue
            elif node.tag in ['td', 'th'] and in_table:
                table_data[-1].append(current_cell_instructions)
                table_spans[-1].append((current_rowspan, current_colspan))
                in_cell = False
                current_cell_instructions = []
                continue
                        
            # Block boundaries (only if not in table)
            if not in_table and check_new_instruction_block(node.tag):
                if instructions_block:
                    instructions_list.append(instructions_block)
                    instructions_block = []
    
    # Catch remaining block
    if instructions_block:
        instructions_list.append(instructions_block)
            
    with open('test.txt', 'w',encoding='utf-8') as f:
        for instruction_block in instructions_list:
            f.write(str(instruction_block))
            f.write('\n')
    
    return instructions_list