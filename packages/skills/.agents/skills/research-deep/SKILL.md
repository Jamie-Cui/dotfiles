---
name: research-deep
description: Read a research outline and perform deep item-by-item research with resumable outputs. Use when each outline item needs an individual pass. Keep the workflow portable across agents and operating systems by preferring sequential or tool-parallel execution in the current environment instead of assuming a specific background-agent system.
---

# Research Deep - Deep Research

## Trigger
`/research-deep`

## Workflow

### Step 1: Auto-locate Outline
Find `*/outline.yaml` file in current working directory, read items list, execution config (including items_per_agent).

### Step 2: Resume Check
- Check completed JSON files in output_dir
- Skip completed items

### Step 3: Batch Execution
- Batch by the configured batch size when present
- Process items using the best execution model supported by the current environment:
  - parallel subagents if available
  - local tool parallelism if available
  - otherwise sequential execution
- Do not assume background agents or hidden task output are available

**Parameter Retrieval**:
- `{topic}`: topic field from outline.yaml
- `{item_name}`: item's name field
- `{item_related_info}`: item's complete yaml content (name + category + description etc.)
- `{output_dir}`: execution.output_dir from outline.yaml (default: ./results)
- `{fields_path}`: absolute path to {topic}/fields.yaml
- `{output_path}`: absolute path to {output_dir}/{item_name_slug}.json (slugify item_name: replace spaces with _, remove special chars)
- `{validate_script}`: absolute path to `validate_json.py`, located relative to this skill family on the local filesystem rather than assuming a home-directory skill path

**Hard Constraint**: The following prompt must be strictly reproduced, only replacing variables in {xxx}, do not modify structure or wording.

**Prompt Template**:
```python
prompt = f"""## Task
Research {item_related_info}, output structured JSON to {output_path}

## Field Definitions
Read {fields_path} to get all field definitions

## Output Requirements
1. Output JSON according to fields defined in fields.yaml
2. Mark uncertain field values with [uncertain]
3. Add uncertain array at the end of JSON, listing all uncertain field names
4. All field values must be in English

## Output Path
{output_path}

## Validation
After completing JSON output, run validation script to ensure complete field coverage:
python {validate_script} -f {fields_path} -j {output_path}
Task is complete only after validation passes.
"""
```

**One-shot Example** (topic=aicoding-history, item=GitHub Copilot, cwd=/home/user/research):
```
## Task
Research name: GitHub Copilot
category: International Product
description: Developed by Microsoft/GitHub, first mainstream AI coding assistant, ~40% market share, output structured JSON to /home/user/research/aicoding-history/results/GitHub_Copilot.json

## Field Definitions
Read /home/user/research/aicoding-history/fields.yaml to get all field definitions

## Output Requirements
1. Output JSON according to fields defined in fields.yaml
2. Mark uncertain field values with [uncertain]
3. Add uncertain array at the end of JSON, listing all uncertain field names
4. All field values must be in English

## Output Path
/home/user/research/aicoding-history/results/GitHub_Copilot.json

## Validation
After completing JSON output, run validation script to ensure complete field coverage:
python /home/user/.claude/skills/research/validate_json.py -f /home/user/research/aicoding-history/fields.yaml -j /home/user/research/aicoding-history/results/GitHub_Copilot.json
Task is complete only after validation passes.
```

### Step 4: Wait and Monitor
- Wait for current batch to complete
- Launch next batch if needed
- Display progress in terminal

### Step 5: Summary Report
After all complete, output:
- Completion count
- Failed/uncertain marked items
- Output directory

## Agent Config
- Background execution: optional, only if supported by the current environment
- Task output suppression: optional, only if the execution model supports it
- Resume support: Yes
