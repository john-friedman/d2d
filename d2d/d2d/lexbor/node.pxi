cimport cython
from cpython.exc cimport PyErr_SetNone

from libc.string cimport memcpy, strstr, strchr, strncpy, memset
from libc.stdio cimport printf

DEF MAX_STACK_DEPTH = 1000
DEF MAX_STRING_LEN = 200

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

    def traverse_signals_benchmark(self, bool include_text = False, bool skip_empty = False):
        """Pure C traversal benchmark for signals without Python overhead."""
        cdef lxb_dom_node_t * root = self.node
        cdef lxb_dom_node_t * node = root
        cdef lxb_dom_node_t * parent_ptr
        cdef size_t parent_mem_id

        while node != NULL:
            parent_ptr = node.parent
            parent_mem_id = <size_t>parent_ptr
            
            if include_text or node.type != LXB_DOM_NODE_TYPE_TEXT:
                if not skip_empty or not is_empty_text_node(node):
                    # Enter signal - just traverse, don't count
                    pass

            if node.first_child != NULL:
                node = node.first_child
            else:
                # Exit current node before moving up
                while True:
                    if include_text or node.type != LXB_DOM_NODE_TYPE_TEXT:
                        if not skip_empty or not is_empty_text_node(node):
                            parent_ptr = node.parent
                            parent_mem_id = <size_t>parent_ptr
                            # Exit signal - just traverse, don't count
                            pass
                    
                    if node == root or node.next != NULL:
                        break
                    node = node.parent
                
                if node == root:
                    break
                node = node.next

    def convert_html_to_instructions(self, str filename):
        """Convert HTML to instructions, extracting raw tag + style data."""
        cdef lxb_dom_node_t *root = self.node
        cdef lxb_dom_node_t *node = root
        cdef lxb_dom_attr_t *style_attr
        cdef const lxb_char_t *style_value
        cdef const lxb_char_t *tag_name
        cdef unsigned char *text_content
        cdef size_t str_len
        cdef lxb_tag_id_t tag_id
        cdef size_t i
        cdef bint is_empty
        
        # Pre-allocate 2MB buffer for writing
        cdef bytearray buffer = bytearray(2 * 1024 * 1024)
        cdef size_t pos = 0
        cdef size_t capacity = len(buffer)
        
        # Stacks: [depth][string_value]
        cdef char bold_stack[1000][200]
        cdef int bold_depth = 0
        cdef char italic_stack[1000][200]
        cdef int italic_depth = 0
        cdef char underline_stack[1000][200]
        cdef int underline_depth = 0
        cdef char text_center_stack[1000][200]
        cdef int text_center_depth = 0
        cdef char font_size_stack[1000][200]
        cdef int font_size_depth = 0
        
        # Scalars: just pointers
        cdef const char* current_href = NULL
        cdef const char* current_src = NULL
        cdef const char* current_alt = NULL
        
        # Block tracking
        cdef bint in_block = False
        cdef bint skip_node = False
        
        with open(filename, 'wb') as f:
            while node != NULL:
                tag_id = lxb_dom_node_tag_id_noi(node)
                
                # Skip display:none nodes
                if skip_node:
                    if node.first_child != NULL:
                        node = node.first_child
                        continue
                    else:
                        while True:
                            # Check if this node set skip_node
                            if node.type == LXB_DOM_NODE_TYPE_ELEMENT:
                                style_attr = lxb_dom_element_attr_by_name(
                                    <lxb_dom_element_t*>node,
                                    <lxb_char_t*>"style",
                                    5
                                )
                                if style_attr != NULL:
                                    style_value = lxb_dom_attr_value_noi(style_attr, &str_len)
                                    if style_value != NULL:
                                        if strstr(<const char*>style_value, "display"):
                                            if strstr(<const char*>style_value, "none"):
                                                skip_node = False
                            
                            if node == root or node.next != NULL:
                                break
                            node = node.parent
                        
                        if node == root:
                            break
                        node = node.next
                        continue
                
                # TEXT NODE: Record text with accumulated attributes
                if node.type == LXB_DOM_NODE_TYPE_TEXT:
                    text_content = <unsigned char *> lexbor_str_data_noi(&(<lxb_dom_character_data_t *> node).data)
                    str_len = (<lxb_dom_character_data_t *> node).data.length
                    
                    if text_content != NULL and str_len > 0:
                        # Check if text is only whitespace
                        is_empty = True
                        for i in range(str_len):
                            if text_content[i] != 32 and text_content[i] != 9 and text_content[i] != 10 and text_content[i] != 13:
                                is_empty = False
                                break
                        
                        if not is_empty:
                            # Start block if needed
                            if not in_block:
                                if pos + 10 > capacity:
                                    f.write(buffer[:pos])
                                    pos = 0
                                buffer[pos] = ord(b'[')
                                pos += 1
                                in_block = True
                            else:
                                # Add comma separator
                                if pos + 10 > capacity:
                                    f.write(buffer[:pos])
                                    pos = 0
                                buffer[pos] = ord(b',')
                                pos += 1
                            
                            # Flush if needed
                            if pos + str_len + 1000 > capacity:
                                f.write(buffer[:pos])
                                pos = 0
                            
                            # Write instruction as JSON: {"text":"...","bold":"..."}
                            memcpy(&buffer[pos], b'{"text":"', 9)
                            pos += 9
                            
                            # Escape and copy text
                            for i in range(str_len):
                                if text_content[i] == ord(b'"'):
                                    buffer[pos] = ord(b'\\')
                                    pos += 1
                                    buffer[pos] = ord(b'"')
                                    pos += 1
                                elif text_content[i] == ord(b'\\'):
                                    buffer[pos] = ord(b'\\')
                                    pos += 1
                                    buffer[pos] = ord(b'\\')
                                    pos += 1
                                elif text_content[i] == ord(b'\n'):
                                    buffer[pos] = ord(b'\\')
                                    pos += 1
                                    buffer[pos] = ord(b'n')
                                    pos += 1
                                else:
                                    buffer[pos] = text_content[i]
                                    pos += 1
                            
                            buffer[pos] = ord(b'"')
                            pos += 1
                            
                            # Add stack values (top of each stack)
                            if bold_depth > 0:
                                memcpy(&buffer[pos], b',"bold":"', 9)
                                pos += 9
                                i = 0
                                while bold_stack[bold_depth - 1][i] != 0 and i < 200:
                                    buffer[pos] = bold_stack[bold_depth - 1][i]
                                    pos += 1
                                    i += 1
                                buffer[pos] = ord(b'"')
                                pos += 1
                            
                            if italic_depth > 0:
                                memcpy(&buffer[pos], b',"italic":"', 11)
                                pos += 11
                                i = 0
                                while italic_stack[italic_depth - 1][i] != 0 and i < 200:
                                    buffer[pos] = italic_stack[italic_depth - 1][i]
                                    pos += 1
                                    i += 1
                                buffer[pos] = ord(b'"')
                                pos += 1
                            
                            if underline_depth > 0:
                                memcpy(&buffer[pos], b',"underline":"', 14)
                                pos += 14
                                i = 0
                                while underline_stack[underline_depth - 1][i] != 0 and i < 200:
                                    buffer[pos] = underline_stack[underline_depth - 1][i]
                                    pos += 1
                                    i += 1
                                buffer[pos] = ord(b'"')
                                pos += 1
                            
                            if text_center_depth > 0:
                                memcpy(&buffer[pos], b',"text-center":"', 16)
                                pos += 16
                                i = 0
                                while text_center_stack[text_center_depth - 1][i] != 0 and i < 200:
                                    buffer[pos] = text_center_stack[text_center_depth - 1][i]
                                    pos += 1
                                    i += 1
                                buffer[pos] = ord(b'"')
                                pos += 1
                            
                            if font_size_depth > 0:
                                memcpy(&buffer[pos], b',"font-size":"', 14)
                                pos += 14
                                i = 0
                                while font_size_stack[font_size_depth - 1][i] != 0 and i < 200:
                                    buffer[pos] = font_size_stack[font_size_depth - 1][i]
                                    pos += 1
                                    i += 1
                                buffer[pos] = ord(b'"')
                                pos += 1
                            
                            # Add scalars
                            if current_href != NULL:
                                memcpy(&buffer[pos], b',"href":"', 9)
                                pos += 9
                                i = 0
                                while current_href[i] != 0 and i < 500:
                                    buffer[pos] = current_href[i]
                                    pos += 1
                                    i += 1
                                buffer[pos] = ord(b'"')
                                pos += 1
                            
                            buffer[pos] = ord(b'}')
                            pos += 1
                
                # ENTER: Element node - accumulate styles
                elif node.type == LXB_DOM_NODE_TYPE_ELEMENT:
                    # Track how many we push for this node
                    cdef int node_bold_pushed = 0
                    cdef int node_italic_pushed = 0
                    cdef int node_underline_pushed = 0
                    
                    # Handle tag-based styles FIRST (tags push before CSS)
                    if tag_id == LXB_TAG_B or tag_id == LXB_TAG_STRONG:
                        if bold_depth < 1000:
                            strncpy(bold_stack[bold_depth], "bold", 199)
                            bold_stack[bold_depth][199] = 0
                            bold_depth += 1
                            node_bold_pushed = 1
                    
                    elif tag_id == LXB_TAG_I or tag_id == LXB_TAG_EM:
                        if italic_depth < 1000:
                            strncpy(italic_stack[italic_depth], "italic", 199)
                            italic_stack[italic_depth][199] = 0
                            italic_depth += 1
                            node_italic_pushed = 1
                    
                    elif tag_id == LXB_TAG_U or tag_id == LXB_TAG_INS:
                        if underline_depth < 1000:
                            strncpy(underline_stack[underline_depth], "underline", 199)
                            underline_stack[underline_depth][199] = 0
                            underline_depth += 1
                            node_underline_pushed = 1
                    
                    elif tag_id == LXB_TAG_A:
                        # Handle href scalar
                        style_attr = lxb_dom_element_attr_by_name(
                            <lxb_dom_element_t*>node,
                            <lxb_char_t*>"href",
                            4
                        )
                        if style_attr != NULL:
                            current_href = <const char*>lxb_dom_attr_value_noi(style_attr, &str_len)
                    
                    # Get style attribute for CSS-based styles (pushed AFTER tags)
                    style_attr = lxb_dom_element_attr_by_name(
                        <lxb_dom_element_t*>node,
                        <lxb_char_t*>"style",
                        5
                    )
                    
                    if style_attr != NULL:
                        style_value = lxb_dom_attr_value_noi(style_attr, &str_len)
                        if style_value != NULL and str_len > 0:
                            # Check for display:none
                            if strstr(<const char*>style_value, "display"):
                                if strstr(<const char*>style_value, "none"):
                                    skip_node = True
                            
                            # Check for bold (CSS overrides tag)
                            if strstr(<const char*>style_value, "font-weight"):
                                if strstr(<const char*>style_value, "bold") or strstr(<const char*>style_value, "700"):
                                    if bold_depth < 1000:
                                        strncpy(bold_stack[bold_depth], "font-weight:bold", 199)
                                        bold_stack[bold_depth][199] = 0
                                        bold_depth += 1
                                        node_bold_pushed += 1
                            
                            # Check for italic
                            if strstr(<const char*>style_value, "font-style"):
                                if strstr(<const char*>style_value, "italic"):
                                    if italic_depth < 1000:
                                        strncpy(italic_stack[italic_depth], "font-style:italic", 199)
                                        italic_stack[italic_depth][199] = 0
                                        italic_depth += 1
                                        node_italic_pushed += 1
                            
                            # Check for underline
                            if strstr(<const char*>style_value, "text-decoration"):
                                if strstr(<const char*>style_value, "underline"):
                                    if underline_depth < 1000:
                                        strncpy(underline_stack[underline_depth], "text-decoration:underline", 199)
                                        underline_stack[underline_depth][199] = 0
                                        underline_depth += 1
                                        node_underline_pushed += 1
                            
                            # TODO: Extract font-size, text-align:center, etc.
                
                # Traverse down
                if node.first_child != NULL:
                    node = node.first_child
                else:
                    # EXIT nodes while going back up
                    while True:
                        tag_id = lxb_dom_node_tag_id_noi(node)
                        
                        # Pop stacks by re-parsing (inefficient but simple)
                        if node.type == LXB_DOM_NODE_TYPE_ELEMENT:
                            cdef int to_pop_bold = 0
                            cdef int to_pop_italic = 0
                            cdef int to_pop_underline = 0
                            
                            # Check tag-based styles
                            if tag_id == LXB_TAG_B or tag_id == LXB_TAG_STRONG:
                                to_pop_bold = 1
                            elif tag_id == LXB_TAG_I or tag_id == LXB_TAG_EM:
                                to_pop_italic = 1
                            elif tag_id == LXB_TAG_U or tag_id == LXB_TAG_INS:
                                to_pop_underline = 1
                            elif tag_id == LXB_TAG_A:
                                current_href = NULL
                            
                            # Check CSS-based styles
                            style_attr = lxb_dom_element_attr_by_name(
                                <lxb_dom_element_t*>node,
                                <lxb_char_t*>"style",
                                5
                            )
                            
                            if style_attr != NULL:
                                style_value = lxb_dom_attr_value_noi(style_attr, &str_len)
                                if style_value != NULL and str_len > 0:
                                    if strstr(<const char*>style_value, "font-weight"):
                                        if strstr(<const char*>style_value, "bold") or strstr(<const char*>style_value, "700"):
                                            to_pop_bold += 1
                                    
                                    if strstr(<const char*>style_value, "font-style"):
                                        if strstr(<const char*>style_value, "italic"):
                                            to_pop_italic += 1
                                    
                                    if strstr(<const char*>style_value, "text-decoration"):
                                        if strstr(<const char*>style_value, "underline"):
                                            to_pop_underline += 1
                            
                            # Pop from stacks
                            bold_depth -= to_pop_bold
                            italic_depth -= to_pop_italic
                            underline_depth -= to_pop_underline
                            
                            # Clamp to zero
                            if bold_depth < 0: bold_depth = 0
                            if italic_depth < 0: italic_depth = 0
                            if underline_depth < 0: underline_depth = 0
                        
                        # Check if block-level element - trigger BLOCK_END
                        if (tag_id == LXB_TAG_P or tag_id == LXB_TAG_DIV or 
                            tag_id == LXB_TAG_H1 or tag_id == LXB_TAG_H2 or 
                            tag_id == LXB_TAG_H3 or tag_id == LXB_TAG_H4 or 
                            tag_id == LXB_TAG_H5 or tag_id == LXB_TAG_H6 or
                            tag_id == LXB_TAG_LI or tag_id == LXB_TAG_BR):
                            
                            if in_block:
                                # Close block
                                if pos + 10 > capacity:
                                    f.write(buffer[:pos])
                                    pos = 0
                                
                                buffer[pos] = ord(b']')
                                pos += 1
                                buffer[pos] = ord(b'\n')
                                pos += 1
                                
                                in_block = False
                                
                                # Reset all stacks and scalars
                                bold_depth = 0
                                italic_depth = 0
                                underline_depth = 0
                                text_center_depth = 0
                                font_size_depth = 0
                                current_href = NULL
                                current_src = NULL
                                current_alt = NULL
                        
                        if node == root or node.next != NULL:
                            break
                        node = node.parent
                    
                    if node == root:
                        break
                    node = node.next
            
            # Close any remaining block
            if in_block:
                if pos + 10 > capacity:
                    f.write(buffer[:pos])
                    pos = 0
                buffer[pos] = ord(b']')
                pos += 1
                buffer[pos] = ord(b'\n')
                pos += 1
            
            # Final flush
            if pos > 0:
                f.write(buffer[:pos])