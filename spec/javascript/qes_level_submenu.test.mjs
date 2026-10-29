import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import * as compiler from '@vue/compiler-sfc'
import * as vue from 'vue'

import qesI18n from '../../app/javascript/template_builder/qes_i18n.js'

const SUBMENU = new URL('../../app/javascript/template_builder/qes_level_submenu.vue', import.meta.url)

// Komponenta se mountuje bez DOM: vlastní renderer s minimálním hostem. Test tak
// ověří skutečný render (nález #6: šablona sahala na modulový import přes `this`).
const node = (tag, text = '') => ({ tag, text, children: [], props: {}, parent: null })

const host = {
  createElement: (tag) => node(tag),
  createText: (text) => node('#text', text),
  createComment: (text) => node('#comment', text),
  setText: (n, text) => { n.text = text },
  setElementText: (n, text) => { n.children = [node('#text', text)] },
  insert: (child, parent, anchor) => {
    child.parent = parent

    const index = anchor ? parent.children.indexOf(anchor) : -1

    if (index < 0) {
      parent.children.push(child)
    } else {
      parent.children.splice(index, 0, child)
    }
  },
  remove: (child) => {
    const index = child.parent ? child.parent.children.indexOf(child) : -1

    if (index >= 0) child.parent.children.splice(index, 1)
  },
  parentNode: (n) => n.parent,
  nextSibling: (n) => {
    const index = n.parent ? n.parent.children.indexOf(n) : -1

    return index < 0 ? null : n.parent.children[index + 1] || null
  },
  patchProp: (el, key, _prev, value) => { el.props[key] = value },
  querySelector: () => null,
  setScopeId: () => {},
  cloneNode: (n) => JSON.parse(JSON.stringify(n)),
  insertStaticContent: () => [node('div'), node('div')]
}

const toRequires = (code) => code.replace(
  /^import\s+(?:\{([^}]*)\}|(\w+))\s+from\s+["']([^"']+)["']/gm,
  (_match, named, name, from) => named
    ? `const { ${named.replace(/\s+as\s+/g, ': ')} } = __stubs[${JSON.stringify(from)}]`
    : `const ${name} = __stubs[${JSON.stringify(from)}]`
)

function mount (field) {
  const { descriptor } = compiler.parse(readFileSync(SUBMENU, 'utf8'))
  const script = compiler.compileScript(descriptor, { id: 'qes-level' }).content
  const template = compiler.compileTemplate({
    source: descriptor.template.content,
    id: 'qes-level',
    filename: 'qes_level_submenu.vue',
    mode: 'module'
  })

  const stubs = {
    vue,
    '@tabler/icons-vue': { IconWritingSign: 'writing-sign', IconCheck: 'check' },
    './field_context_submenu.vue': {
      name: 'ContextSubmenu',
      props: ['icon', 'label', 'options', 'modelValue'],
      render () {
        return vue.h('submenu', { label: this.label }, this.$slots.default ? this.$slots.default() : [])
      }
    },
    './qes_i18n': qesI18n
  }

  const component = {}

  // Test vyhodnocuje zkompilovaný SFC bez bundleru; `new Function` je zde záměr.
  // eslint-disable-next-line no-new-func
  new Function('exports', '__stubs',
    toRequires(script).replace(/^export default/m, 'exports.component =') + '\n' +
    toRequires(template.code).replace(/^export function render/m, 'function render') +
    '\nexports.component.render = render;')(component, stubs)

  const errors = []
  const emitted = []
  const app = vue.createRenderer(host).createApp({
    render () {
      return vue.h(component.component, {
        field,
        onSave: () => emitted.push('save'),
        onClose: () => emitted.push('close')
      })
    }
  })

  app.config.errorHandler = (error) => errors.push(error.message)
  app.config.warnHandler = () => {}

  const root = node('#root')

  app.mount(root)

  const nodes = []
  const walk = (n) => {
    nodes.push(n)
    n.children.forEach(walk)
  }

  walk(root)

  return { errors, emitted, nodes }
}

const buttonLabels = (nodes) => nodes
  .filter((n) => n.tag === 'button')
  .map((n) => n.children[0].children[0].text)

test('vykreslí submenu úrovně podpisu s aktuální úrovní', () => {
  const { errors, nodes } = mount({ type: 'qes', preferences: {} })

  assert.deepEqual(errors, [])
  assert.equal(nodes.find((n) => n.tag === 'submenu').props.label, qesI18n.en.qes_level)
})

test('nechá QES viditelné, ale neaktivní, s vysvětlením', () => {
  const { errors, nodes } = mount({ type: 'qes', preferences: {} })
  const buttons = nodes.filter((n) => n.tag === 'button')

  assert.deepEqual(errors, [])
  assert.deepEqual(buttonLabels(nodes), [qesI18n.en.qes_level_ades, qesI18n.en.qes_level_qes])
  assert.equal(buttons[0].props.disabled, false)
  assert.equal(buttons[1].props.disabled, true)
  assert.ok(nodes.some((n) => n.tag === '#text' && n.text === qesI18n.en.qes_level_unavailable))
})

test('výběr AdES uloží preferences.level a emituje save + close', () => {
  const field = { type: 'qes', preferences: {} }
  const { emitted, nodes } = mount(field)

  nodes.find((n) => n.tag === 'button').props.onClick()

  assert.equal(field.preferences.level, 'ades')
  assert.deepEqual(emitted, ['save', 'close'])
})

test('zobrazí QES jako aktuální úroveň, i když nejde zvolit', () => {
  const { errors, nodes } = mount({ type: 'qes', preferences: { level: 'qes' } })
  const buttons = nodes.filter((n) => n.tag === 'button')

  assert.deepEqual(errors, [])
  assert.equal(buttons[1].props.disabled, true)
  assert.ok(buttons[1].children.some((n) => n.tag === 'check'))
  assert.ok(!buttons[0].children.some((n) => n.tag === 'check'))
})
