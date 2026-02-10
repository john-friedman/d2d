cimport cython
from cpython.exc cimport PyErr_SetNone

from libc.string cimport memcpy, strcmp, strncpy
from libc.stdio cimport printf

DEF MAX_STACK_DEPTH = 1000

import logging

logger = logging.getLogger("selectolax")

_TAG_TO_NAME = {
    0x0005: "-doctype",
    0x0002: "-text",
    0x0004: "-comment",
}

ctypedef fused str_or_LexborNode:
    str
    bytes
    LexborNode

ctypedef fused str_or_bytes:
    str
    bytes

cdef inline bytes to_bytes(str_or_LexborNode value):
    cdef bytes bytes_val
    if isinstance(value, unicode):
        bytes_val = <bytes> value.encode("utf-8")
    elif isinstance(value, bytes):
        bytes_val = <bytes> value
    return bytes_val

# Helper struct for instruction attributes
cdef struct InstructionAttrs:
    char font_weight[32]
    char font_size[32]
    char href[512]
    char header_tag[8]
    bint is_italic
    bint is_underline
    bint is_text_center
    bint display_none

# Style stack entry
cdef struct StyleStackEntry:
    size_t mem_id
    InstructionAttrs attrs


@cython.final
cdef class LexborNode:
    """A class that represents HTML node (element)."""

    cdef void set_as_fragment_root(self):
        self._is_fragment_root = 1

    @staticmethod
    cdef LexborNode new(lxb_dom_node_t *node, LexborHTMLParser parser):
        cdef LexborNode lxbnode = LexborNode.__new__(LexborNode)
        lxbnode.node = node
        lxbnode.parser = parser
        lxbnode._is_fragment_root = 0
        return lxbnode

    @property
    def mem_id(self):
        return <size_t> self.node

    cdef inline bint _check_new_instruction_block(self, lxb_tag_id_t tag_id):
        """Check if this tag should create a new instruction block."""
        return (tag_id == LXB_TAG_P or 
                tag_id == LXB_TAG_DIV or
                tag_id == LXB_TAG_H1 or
                tag_id == LXB_TAG_H2 or
                tag_id == LXB_TAG_H3 or
                tag_id == LXB_TAG_H4 or
                tag_id == LXB_TAG_H5 or
                tag_id == LXB_TAG_H6 or
                tag_id == LXB_TAG_LI or
                tag_id == LXB_TAG_BR)
    
    cdef bint _parse_style(self, str style, InstructionAttrs* attrs):
        """Parse inline style attribute."""
        if not style:
            return False
        
        cdef bint modified = False
        cdef list properties = style.split(';')
        cdef str prop, key, value
        cdef bytes key_bytes, value_bytes
        
        for prop in properties:
            if ':' not in prop:
                continue
            
            parts = prop.split(':', 1)
            key = parts[0].strip().lower()
            value = parts[1].strip().lower()
            
            if key == 'font-weight':
                value_bytes = value.encode('utf-8')
                strncpy(attrs.font_weight, <char*>value_bytes, 31)
                attrs.font_weight[31] = '\0'
                modified = True
            elif key == 'font-style':
                if 'italic' in value:
                    attrs.is_italic = True
                    modified = True
            elif key == 'text-decoration':
                if 'underline' in value:
                    attrs.is_underline = True
                    modified = True
            elif key == 'text-align':
                if 'center' in value:
                    attrs.is_text_center = True
                    modified = True
            elif key == 'font-size':
                value_bytes = value.encode('utf-8')
                strncpy(attrs.font_size, <char*>value_bytes, 31)
                attrs.font_size[31] = '\0'
                modified = True
            elif key == 'display':
                if 'none' in value:
                    attrs.display_none = True
                    modified = True
        
        return modified

    def convert_html_to_instructions(self):
        """Convert HTML to instructions and write to file."""
        cdef lxb_dom_node_t *root = self.node
        cdef lxb_dom_node_t *node = root
        
        # Attribute access variables
        cdef lxb_dom_attr_t *attr
        cdef const lxb_char_t *key
        cdef const lxb_char_t *value
        cdef size_t key_len, value_len
        cdef lxb_tag_id_t tag_id
        cdef const lxb_char_t *text
        
        # Style stack
        cdef StyleStackEntry[MAX_STACK_DEPTH] style_stack
        cdef int stack_depth = 0
        cdef InstructionAttrs current_attrs
        cdef bint modified
        
        # Table tracking
        cdef bint in_table = False
        cdef bint in_cell = False
        cdef list table_data = []
        cdef list table_spans = []
        cdef list current_cell_instructions = []
        cdef int current_rowspan = 1
        cdef int current_colspan = 1
        
        # Display:none tracking
        cdef bint skip_subtree = False
        cdef size_t skip_mem_id = 0
        
        # Instruction block
        cdef list instructions_block = []
        
        # Initialize base attributes
        cdef InstructionAttrs base_attrs
        base_attrs.font_weight[0] = '\0'
        base_attrs.font_size[0] = '\0'
        base_attrs.href[0] = '\0'
        base_attrs.header_tag[0] = '\0'
        base_attrs.is_italic = False
        base_attrs.is_underline = False
        base_attrs.is_text_center = False
        base_attrs.display_none = False
        
        # Push base to stack
        style_stack[0].mem_id = 0
        memcpy(&style_stack[0].attrs, &base_attrs, sizeof(InstructionAttrs))
        stack_depth = 1
        
        # Helper variables
        cdef dict instruction
        cdef str text_str
        cdef str style_str
        cdef bytes tag_bytes
        
        # Open output file
        try:
            f = open('test.txt', 'w', encoding='utf-8')
        except Exception as e:
            raise RuntimeError(f"Failed to open output file: {e}")
        
        try:
            # Main traversal loop
            while node != NULL:
                # ENTER SIGNAL
                if not skip_subtree:
                    tag_id = lxb_dom_node_tag_id_noi(node)
                    
                    # Handle table structure
                    if tag_id == LXB_TAG_TABLE:
                        in_table = True
                        table_data = []
                        table_spans = []
                    elif tag_id == LXB_TAG_TR and in_table:
                        table_data.append([])
                        table_spans.append([])
                    elif (tag_id == LXB_TAG_TD or tag_id == LXB_TAG_TH) and in_table:
                        in_cell = True
                        current_cell_instructions = []
                        current_rowspan = 1
                        current_colspan = 1
                        
                        # Get rowspan/colspan
                        if node.type == LXB_DOM_NODE_TYPE_ELEMENT:
                            attr = lxb_dom_element_first_attribute_noi(<lxb_dom_element_t*>node)
                            while attr != NULL:
                                key = lxb_dom_attr_local_name_noi(attr, &key_len)
                                value = lxb_dom_attr_value_noi(attr, &value_len)
                                if key != NULL and value != NULL:
                                    if key_len == 7 and strcmp(<char*>key, "rowspan") == 0:
                                        try:
                                            current_rowspan = int(value[:value_len].decode('utf-8'))
                                        except:
                                            current_rowspan = 1
                                    elif key_len == 7 and strcmp(<char*>key, "colspan") == 0:
                                        try:
                                            current_colspan = int(value[:value_len].decode('utf-8'))
                                        except:
                                            current_colspan = 1
                                attr = attr.next
                    
                    # Handle text nodes
                    if tag_id == LXB_TAG__TEXT:
                        text = <const lxb_char_t*>lexbor_str_data_noi(&(<lxb_dom_character_data_t*>node).data)
                        if text != NULL:
                            text_str = text.decode('utf-8')
                            if text_str.strip() != '':
                                instruction = {'text': text_str}
                                
                                # Apply current style attributes
                                current_attrs = style_stack[stack_depth - 1].attrs
                                if current_attrs.font_weight[0] != '\0':
                                    instruction['font_weight'] = current_attrs.font_weight.decode('utf-8')
                                if current_attrs.font_size[0] != '\0':
                                    instruction['font_size'] = current_attrs.font_size.decode('utf-8')
                                if current_attrs.header_tag[0] != '\0':
                                    instruction['header_tag'] = current_attrs.header_tag.decode('utf-8')
                                if current_attrs.href[0] != '\0':
                                    instruction['href'] = current_attrs.href.decode('utf-8')
                                if current_attrs.is_italic:
                                    instruction['is_italic'] = True
                                if current_attrs.is_underline:
                                    instruction['is_underline'] = True
                                if current_attrs.is_text_center:
                                    instruction['is_text_center'] = True
                                
                                if in_cell:
                                    current_cell_instructions.append(instruction)
                                else:
                                    instructions_block.append(instruction)
                    
                    # Handle img nodes
                    elif tag_id == LXB_TAG_IMG:
                        instruction = {}
                        if node.type == LXB_DOM_NODE_TYPE_ELEMENT:
                            attr = lxb_dom_element_first_attribute_noi(<lxb_dom_element_t*>node)
                            while attr != NULL:
                                key = lxb_dom_attr_local_name_noi(attr, &key_len)
                                value = lxb_dom_attr_value_noi(attr, &value_len)
                                if key != NULL:
                                    if key_len == 3 and strcmp(<char*>key, "src") == 0:
                                        if value != NULL:
                                            instruction['src'] = value[:value_len].decode('utf-8')
                                    elif key_len == 3 and strcmp(<char*>key, "alt") == 0:
                                        if value != NULL:
                                            instruction['alt'] = value[:value_len].decode('utf-8')
                                attr = attr.next
                        
                        # Apply font attributes
                        current_attrs = style_stack[stack_depth - 1].attrs
                        if current_attrs.font_weight[0] != '\0':
                            instruction['font_weight'] = current_attrs.font_weight.decode('utf-8')
                        if current_attrs.font_size[0] != '\0':
                            instruction['font_size'] = current_attrs.font_size.decode('utf-8')
                        
                        if in_cell:
                            current_cell_instructions.append(instruction)
                        else:
                            instructions_block.append(instruction)
                    
                    # Handle other tags - check for styling
                    else:
                        if node.type == LXB_DOM_NODE_TYPE_ELEMENT:
                            # Copy parent attrs
                            memcpy(&current_attrs, &style_stack[stack_depth - 1].attrs, sizeof(InstructionAttrs))
                            modified = False
                            
                            # Tag-based styling
                            if tag_id == LXB_TAG_B or tag_id == LXB_TAG_STRONG:
                                if tag_id == LXB_TAG_B:
                                    strncpy(current_attrs.font_weight, "b", 31)
                                else:
                                    strncpy(current_attrs.font_weight, "strong", 31)
                                current_attrs.font_weight[31] = '\0'
                                modified = True
                            elif tag_id == LXB_TAG_H1:
                                strncpy(current_attrs.header_tag, "h1", 7)
                                current_attrs.header_tag[7] = '\0'
                                modified = True
                            elif tag_id == LXB_TAG_H2:
                                strncpy(current_attrs.header_tag, "h2", 7)
                                current_attrs.header_tag[7] = '\0'
                                modified = True
                            elif tag_id == LXB_TAG_H3:
                                strncpy(current_attrs.header_tag, "h3", 7)
                                current_attrs.header_tag[7] = '\0'
                                modified = True
                            elif tag_id == LXB_TAG_H4:
                                strncpy(current_attrs.header_tag, "h4", 7)
                                current_attrs.header_tag[7] = '\0'
                                modified = True
                            elif tag_id == LXB_TAG_H5:
                                strncpy(current_attrs.header_tag, "h5", 7)
                                current_attrs.header_tag[7] = '\0'
                                modified = True
                            elif tag_id == LXB_TAG_H6:
                                strncpy(current_attrs.header_tag, "h6", 7)
                                current_attrs.header_tag[7] = '\0'
                                modified = True
                            elif tag_id == LXB_TAG_I or tag_id == LXB_TAG_EM:
                                current_attrs.is_italic = True
                                modified = True
                            elif tag_id == LXB_TAG_U or tag_id == LXB_TAG_INS:
                                current_attrs.is_underline = True
                                modified = True
                            elif tag_id == LXB_TAG_A:
                                # Get href attribute
                                attr = lxb_dom_element_first_attribute_noi(<lxb_dom_element_t*>node)
                                while attr != NULL:
                                    key = lxb_dom_attr_local_name_noi(attr, &key_len)
                                    value = lxb_dom_attr_value_noi(attr, &value_len)
                                    if key != NULL and key_len == 4 and strcmp(<char*>key, "href") == 0:
                                        if value != NULL:
                                            strncpy(current_attrs.href, <char*>value, 511)
                                            current_attrs.href[511] = '\0'
                                        else:
                                            current_attrs.href[0] = '\0'
                                        modified = True
                                        break
                                    attr = attr.next
                            
                            # Parse inline style attribute
                            attr = lxb_dom_element_first_attribute_noi(<lxb_dom_element_t*>node)
                            while attr != NULL:
                                key = lxb_dom_attr_local_name_noi(attr, &key_len)
                                value = lxb_dom_attr_value_noi(attr, &value_len)
                                if key != NULL and key_len == 5 and strcmp(<char*>key, "style") == 0:
                                    if value != NULL:
                                        style_str = value[:value_len].decode('utf-8')
                                        if self._parse_style(style_str, &current_attrs):
                                            modified = True
                                    break
                                attr = attr.next
                            
                            # Check for display:none
                            if current_attrs.display_none:
                                skip_subtree = True
                                skip_mem_id = <size_t>node
                            
                            # Push to stack if modified
                            if modified:
                                if stack_depth >= MAX_STACK_DEPTH:
                                    raise RuntimeError("Style stack overflow")
                                style_stack[stack_depth].mem_id = <size_t>node
                                memcpy(&style_stack[stack_depth].attrs, &current_attrs, sizeof(InstructionAttrs))
                                stack_depth += 1
                
                # Traverse to next node
                if node.first_child != NULL:
                    node = node.first_child
                else:
                    # EXIT SIGNAL LOOP
                    while True:
                        # Handle display:none exit
                        if skip_subtree and <size_t>node == skip_mem_id:
                            skip_subtree = False
                            skip_mem_id = 0
                        
                        # Pop style stack
                        if stack_depth > 1 and style_stack[stack_depth - 1].mem_id == <size_t>node:
                            stack_depth -= 1
                        
                        tag_id = lxb_dom_node_tag_id_noi(node)
                        
                        # Handle table structure exit
                        if tag_id == LXB_TAG_TABLE:
                            instructions_block.append({
                                'table_data': table_data,
                                'table_spans': table_spans
                            })
                            in_table = False
                            table_data = []
                            table_spans = []
                        elif (tag_id == LXB_TAG_TD or tag_id == LXB_TAG_TH) and in_table:
                            if len(table_data) > 0:
                                table_data[-1].append(current_cell_instructions)
                                table_spans[-1].append((current_rowspan, current_colspan))
                            in_cell = False
                            current_cell_instructions = []
                        
                        # Block boundaries
                        if not in_table and self._check_new_instruction_block(tag_id):
                            if len(instructions_block) > 0:
                                f.write(str(instructions_block))
                                f.write('\n')
                                instructions_block = []
                        
                        if node == root or node.next != NULL:
                            break
                        node = node.parent
                    
                    if node == root:
                        break
                    node = node.next
            
            # Write remaining block
            if len(instructions_block) > 0:
                f.write(str(instructions_block))
                f.write('\n')
        
        finally:
            f.close()