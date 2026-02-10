# doc2dict

## Terminology

- Instruction attributes: a struct of the visual appearance 
- Instruction: a text fragment with instruction attributes
- Instruction block: a list of instructions, representing the same visual section. For example, a series of spans within a \<p\> would be an instruction block.
- Instructions List: A list of instruction blocks. Represents the entire document.

## Structure

Adapters convert files into instructions lists. Transformers into nested format.

- adapters
    - html
        - lexbor
    - pdf
        - pdfium
    - scans
- normalizers
- transformers

## Seperation of observe and interpret

Observe gets the sufficient information needed for interpret.

Interpret constructs the nesting.

This seperation allows us to store instructions, and only modify interpret

## Mapping dictionaries

- rules for how to process instructions

## Storage

Instructions should be parquet.

Columns are keys, depending on adapter source.

Common:
- type
- instruction_block_id (within instruction list)
- instruction_id (within instruction block)
- text_data
- table_data

## Adapters

### HTML

We are building off of lexbor, as it has the fastest performance by far.

#### Instruction
- stacks
- stacks are appended to first by tag, then css, to mirror visual appearance,

Attribute stacks
- bold: e.g. b, font-weight bold
- italic
- underline
- text-center
- font-size

Attribute values (Cant be list)
- href
- src
- alt


Types , value
- text: 'this is text'
- table: \[\[a b\]\[c d\]\]
- image:
