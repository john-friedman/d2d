cimport cython
from cpython.exc cimport PyErr_SetNone

from libc.string cimport memcpy
# remove later
from libc.stdio cimport printf


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
        """Convert HTML to instructions, accumulating CSS and writing blocks to file."""
        cdef lxb_dom_node_t *root = self.node
        cdef lxb_dom_node_t *node = root
        cdef lxb_dom_attr_t *style_attr
        cdef const lxb_char_t *style_value
        cdef const lxb_char_t *tag_name
        cdef unsigned char *text_content
        cdef size_t str_len
        cdef lxb_tag_id_t tag_id
        cdef size_t i
        cdef bint is_empty = True
        
        # Pre-allocate 2MB buffer for writing
        cdef bytearray buffer = bytearray(2 * 1024 * 1024)
        cdef size_t pos = 0
        cdef size_t capacity = len(buffer)
        
        # C-level counters for CSS attributes
        cdef int bold_count = 0
        cdef int italic_count = 0
        cdef int underline_count = 0
        
        with open(filename, 'wb') as f:
            while node != NULL:
                tag_id = lxb_dom_node_tag_id_noi(node)
                
                # TEXT NODE: Record text content (direct pointer) - only if non-empty
                if node.type == LXB_DOM_NODE_TYPE_TEXT:
                    text_content = <unsigned char *> lexbor_str_data_noi(&(<lxb_dom_character_data_t *> node).data)
                    str_len = (<lxb_dom_character_data_t *> node).data.length
                    
                    if text_content != NULL and str_len > 0:
                        # Check if text is only whitespace (fast C-level check)
                        for i in range(str_len):
                            if text_content[i] != 32 and text_content[i] != 9 and text_content[i] != 10 and text_content[i] != 13:  # space, tab, newline, carriage return
                                is_empty = False
                                break
                        
                        if not is_empty:
                            # Flush if needed
                            if pos + str_len + 20 > capacity:
                                f.write(buffer[:pos])
                                pos = 0
                            
                            # Write "TEXT: "
                            memcpy(&buffer[pos], b"TEXT: ", 6)
                            pos += 6
                            memcpy(&buffer[pos], text_content, str_len)
                            pos += str_len
                            buffer[pos] = ord(b'\n')
                            pos += 1
                
                # ENTER: Record tag + style
                elif node.type == LXB_DOM_NODE_TYPE_ELEMENT:
                    tag_name = lxb_dom_element_qualified_name(
                        <lxb_dom_element_t*>node,
                        &str_len
                    )
                    
                    if tag_name != NULL:
                        # Flush if needed
                        if pos + str_len + 1000 > capacity:
                            f.write(buffer[:pos])
                            pos = 0
                        
                        # Write "ENTER: <tagname>"
                        memcpy(&buffer[pos], b"ENTER: ", 7)
                        pos += 7
                        memcpy(&buffer[pos], tag_name, str_len)
                        pos += str_len
                        
                        # Get style attribute
                        style_attr = lxb_dom_element_attr_by_name(
                            <lxb_dom_element_t*>node,
                            <lxb_char_t*>"style",
                            5
                        )
                        
                        if style_attr != NULL:
                            style_value = lxb_dom_attr_value_noi(style_attr, &str_len)
                            if style_value != NULL and str_len > 0:
                                # Write " style="
                                memcpy(&buffer[pos], b" style=", 7)
                                pos += 7
                                memcpy(&buffer[pos], style_value, str_len)
                                pos += str_len
                        
                        buffer[pos] = ord(b'\n')
                        pos += 1
                
                # Traverse down
                if node.first_child != NULL:
                    node = node.first_child
                else:
                    # EXIT nodes while going back up
                    while True:
                        tag_id = lxb_dom_node_tag_id_noi(node)
                        
                        # EXIT: Record tag + style (only for elements)
                        if node.type == LXB_DOM_NODE_TYPE_ELEMENT:
                            tag_name = lxb_dom_element_qualified_name(
                                <lxb_dom_element_t*>node,
                                &str_len
                            )
                            
                            if tag_name != NULL:
                                # Flush if needed
                                if pos + str_len + 1000 > capacity:
                                    f.write(buffer[:pos])
                                    pos = 0
                                
                                # Write "EXIT: <tagname>"
                                memcpy(&buffer[pos], b"EXIT: ", 6)
                                pos += 6
                                memcpy(&buffer[pos], tag_name, str_len)
                                pos += str_len
                                
                                # Get style attribute
                                style_attr = lxb_dom_element_attr_by_name(
                                    <lxb_dom_element_t*>node,
                                    <lxb_char_t*>"style",
                                    5
                                )
                                
                                if style_attr != NULL:
                                    style_value = lxb_dom_attr_value_noi(style_attr, &str_len)
                                    if style_value != NULL and str_len > 0:
                                        # Write " style="
                                        memcpy(&buffer[pos], b" style=", 7)
                                        pos += 7
                                        memcpy(&buffer[pos], style_value, str_len)
                                        pos += str_len
                                
                                buffer[pos] = ord(b'\n')
                                pos += 1
                        
                        # Check if block-level element
                        if (tag_id == LXB_TAG_P or tag_id == LXB_TAG_DIV or 
                            tag_id == LXB_TAG_H1 or tag_id == LXB_TAG_H2 or 
                            tag_id == LXB_TAG_H3 or tag_id == LXB_TAG_H4 or 
                            tag_id == LXB_TAG_H5 or tag_id == LXB_TAG_H6 or
                            tag_id == LXB_TAG_LI or tag_id == LXB_TAG_BR or 
                            tag_id == LXB_TAG_TABLE):
                            
                            # Flush if needed
                            if pos + 100 > capacity:
                                f.write(buffer[:pos])
                                pos = 0
                            
                            # Write "BLOCK_END\n"
                            memcpy(&buffer[pos], b"BLOCK_END\n", 10)
                            pos += 10
                            
                            # Reset counters
                            bold_count = 0
                            italic_count = 0
                            underline_count = 0
                        
                        if node == root or node.next != NULL:
                            break
                        node = node.parent
                    
                    if node == root:
                        break
                    node = node.next
            
            # Final flush
            if pos > 0:
                f.write(buffer[:pos])