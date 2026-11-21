import fs from 'node:fs';
import { replaceFileSync } from './atomic-files.mjs';

export class CodexSettings {
  constructor(file, cacheFile) {
    this.file = file;
    this.cacheFile = cacheFile;
  }

  current() {
    return JSON.parse(fs.readFileSync(this.file, 'utf8'));
  }

  options() {
    const current = this.current();
    let catalog = [];
    try {
      catalog = JSON.parse(fs.readFileSync(this.cacheFile, 'utf8')).models ?? [];
    } catch (error) {
      if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error;
    }
    const models = catalog.filter(model => model.visibility === 'list').map(model => ({
      id: model.slug,
      label: model.display_name,
      efforts: model.supported_reasoning_levels?.map(level => level.effort) ?? [],
      defaultEffort: model.default_reasoning_level,
      fast: model.service_tiers?.some(tier => tier.id === 'priority') ?? false,
    }));
    if (!models.some(model => model.id === current.model)) {
      models.unshift({id: current.model, label: current.model, efforts: [current.effort],
        defaultEffort: current.effort, fast: current.fast});
    }
    return {current, models};
  }

  save(value) {
    const {models} = this.options();
    const model = models.find(option => option.id === value?.model);
    if (!model || !model.efforts.includes(value.effort) || typeof value.fast !== 'boolean' ||
        (value.fast && !model.fast)) {
      throw new Error('此模型、思考强度与 Fast 的组合不可用');
    }
    const current = {model: model.id, effort: value.effort, fast: value.fast};
    const temp = this.file + '.tmp';
    fs.writeFileSync(temp, JSON.stringify(current, null, 2) + '\n');
    replaceFileSync(temp, this.file);
    return {current, models};
  }

  turnParams() {
    const {model, effort, fast} = this.current();
    if (typeof model !== 'string' || !model || typeof effort !== 'string' || typeof fast !== 'boolean') {
      throw new Error('Loom Codex 配置格式无效');
    }
    return {model, effort, serviceTier: fast ? 'priority' : 'default'};
  }
}
