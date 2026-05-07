---
name: notion-notes
description: Create well-structured notes in Notion with proper formatting, dark mode colors, emojis, and organized hierarchy. Use this skill when the user asks to create notes, documentation, or pages in Notion.
---

# Notion Notes Creation Skill

This skill teaches Claude how to create professional, well-organized notes in Notion with consistent formatting and structure.

## When to Use This Skill

Use this skill when the user requests:
- Creating notes in Notion
- Documentation or guides in Notion
- Organizing information in Notion pages
- Setting up structured content with proper hierarchy

## Core Instructions

### 1. Always Search for Parent Pages First

Before creating a note, search for the appropriate parent page:
```
Use notion-search to find the parent page where the note should be created
```

### 2. Use Proper Color Scheme for Dark Mode

Apply text colors to headings (never background colors):
- **Blue** (`<span color="blue">`) - Main sections and primary headings
- **Purple** (`<span color="purple">`) - Category headings and important sections
- **Green** (`<span color="green">`) - Benefits, features, positive items
- **Orange** (`<span color="orange">`) - Tips, warnings, important notes
- **Pink** (`<span color="pink">`) - Call-to-actions, getting started sections

### 3. Strategic Emoji Usage

Add ONE emoji per heading for visual organization:
- 📝 📄 📋 - Documentation and notes
- 🎯 🎪 🎨 - Goals and objectives
- 🛠️ ⚙️ 🔧 - Tools and configuration
- 💡 ⚡ ✨ - Ideas and insights
- 🚀 📦 🎉 - Getting started and launches
- ⚠️ 🔒 🛡️ - Security and warnings

### 4. Standard Note Structure

Follow this template for all notes:

```markdown
# <span color="blue">🎯 Title/Overview</span>
Brief introduction to the topic

---

# <span color="purple">📦 Main Section</span>
Key content goes here

## <span color="blue">Subsection</span>
- Point 1
- Point 2

# <span color="green">✨ Benefits/Features</span>
Positive aspects and highlights

# <span color="orange">💡 Tips & Best Practices</span>
> Important callouts and recommendations

# <span color="pink">🎉 Getting Started</span>
Action steps and next moves
```

### 5. Creating Notes with MCP Tools

**Step 1**: Search for parent page
```
notion-search with query="parent page name"
```

**Step 2**: Create the page
```
notion-create-pages with:
- parent: {"page_id": "parent-id", "type": "page_id"}
- properties: {"title": "Note Title"}
- content: [structured markdown with colors and emojis]
```

**Step 3**: Confirm creation and provide URL to user

## Examples

### Example 1: Meeting Notes

When user says: "Create meeting notes about product roadmap in Notion"

1. Search for appropriate parent (e.g., "Meetings" or "Product")
2. Create page with structure:
   - Overview (blue) - Meeting details
   - Attendees (purple) - Who was there
   - Key Decisions (green) - What was decided
   - Action Items (orange) - Next steps
   - Follow-up (pink) - Timeline

### Example 2: Technical Documentation

When user says: "Create docs for the new API feature"

1. Search for "Documentation" or "Technical" parent page
2. Create page with structure:
   - Overview (blue) - What the feature does
   - Setup (purple) - Installation/configuration
   - Usage Examples (green) - Code snippets
   - Troubleshooting (orange) - Common issues
   - Getting Started (pink) - Quick start guide

### Example 3: Learning Notes

When user says: "Create study notes about React hooks"

1. Search for "Learning" or "Notes" parent page
2. Create page with structure:
   - Overview (blue) - What are hooks
   - Core Concepts (purple) - Main ideas
   - Key Benefits (green) - Why use them
   - Best Practices (orange) - Tips and patterns
   - Practice Examples (pink) - Hands-on exercises

## Guidelines

1. **Always ask for clarification** if the parent page location is unclear
2. **Use consistent color scheme** across all notes
3. **One emoji per heading** - don't overuse
4. **Proper hierarchy** - Use H1, H2, H3 appropriately
5. **Horizontal rules** (`---`) to separate major sections
6. **Code blocks** for technical content with proper language tags
7. **Blockquotes** (`>`) for important tips and warnings
8. **Lists** for organized information (bulleted or numbered)

## Best Practices

- **Test in dark mode**: All colors should be readable in dark mode
- **Consistent formatting**: Use the same patterns across all notes
- **Clear hierarchy**: Make the document structure obvious
- **Actionable content**: Include next steps or call-to-actions
- **Link related pages**: Use `<mention-page>` for cross-references
- **Keep it simple**: Don't over-complicate the structure

## Common Pitfalls to Avoid

❌ Don't use background colors (e.g., `{color="blue_bg"}`)
✅ Use text colors (e.g., `<span color="blue">`)

❌ Don't overuse emojis (multiple per line)
✅ One emoji per heading

❌ Don't create notes without searching for parent first
✅ Always search for the appropriate parent page

❌ Don't use light colors in dark mode
✅ Use bright, readable colors (blue, purple, green, orange, pink)

## Advanced Features

### Cross-referencing Pages
```markdown
See also: <mention-page url="{{URL}}">Related Page</mention-page>
```

### Adding Code Blocks
```markdown
\`\`\`javascript
const example = "use proper syntax highlighting";
\`\`\`
```

### Creating Sub-pages
```markdown
<page>Sub-page Title</page>
```

### Adding Callouts
```markdown
<callout icon="💡" color="orange_bg">
Important information goes here
</callout>
```

## Validation Checklist

Before completing the note creation, verify:
- [ ] Parent page was searched and found
- [ ] Page title is clear and descriptive
- [ ] All headings use text colors (not background)
- [ ] Emojis are used strategically (one per heading)
- [ ] Structure follows the template
- [ ] Content is well-organized with proper hierarchy
- [ ] Dark mode colors are used throughout
- [ ] User receives the Notion URL after creation

## Success Criteria

A well-created note should:
1. Be easy to read in dark mode
2. Have clear visual hierarchy
3. Be properly located in the workspace
4. Follow consistent formatting patterns
5. Include relevant emojis without overdoing it
6. Provide value and be actionable
