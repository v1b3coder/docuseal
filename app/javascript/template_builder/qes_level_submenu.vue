<template>
  <ContextSubmenu
    class="field-settings-qes-level"
    :icon="IconWritingSign"
    :label="qesLevelLabel"
    :model-value="currentQesLevel"
  >
    <button
      v-for="option in qesLevelOptions"
      :key="option.value"
      type="button"
      class="field-settings-qes-level-option w-full px-2 py-1 rounded-md flex items-center justify-between space-x-2 text-sm"
      :class="option.disabled ? 'text-neutral-400 cursor-not-allowed' : 'hover:bg-neutral-100 cursor-pointer'"
      :disabled="option.disabled"
      @click="handleSelectQesLevel(option.value)"
    >
      <span class="whitespace-nowrap">{{ option.label }}</span>
      <IconCheck
        v-if="currentQesLevel === option.value"
        class="w-4 h-4"
      />
    </button>
    <p
      v-if="!qesLevelAvailable"
      class="field-settings-qes-level-unavailable px-2 pt-1 pb-1 text-xs text-neutral-500"
    >
      {{ qesLevelUnavailableHint }}
    </p>
  </ContextSubmenu>
</template>

<script>
import { IconCheck, IconWritingSign } from '@tabler/icons-vue'
import ContextSubmenu from './field_context_submenu.vue'
import qesI18n from './qes_i18n'

export default {
  name: 'QesLevelSubmenu',
  components: { ContextSubmenu, IconCheck },
  props: {
    field: {
      type: Object,
      required: true
    }
  },
  emits: ['save', 'close'],
  data () {
    return { IconWritingSign }
  },
  computed: {
    currentQesLevel () {
      return this.field.preferences?.level || 'ades'
    },
    qesLevelLabel () {
      return qesI18n.en.qes_level
    },
    // QES vyžaduje QcSSCD certifikát z reálné čtečky (SPEC § 9.4); P5 je stub,
    // takže volbu zobrazujeme, ale neaktivní. Po nasazení čtečky se přepne na true.
    qesLevelAvailable () {
      return false
    },
    qesLevelOptions () {
      return [
        { value: 'ades', label: qesI18n.en.qes_level_ades, disabled: false },
        { value: 'qes', label: qesI18n.en.qes_level_qes, disabled: !this.qesLevelAvailable }
      ]
    },
    qesLevelUnavailableHint () {
      return qesI18n.en.qes_level_unavailable
    }
  },
  methods: {
    handleSelectQesLevel (level) {
      this.field.preferences ||= {}
      this.field.preferences.level = level

      this.$emit('save')
      this.$emit('close')
    }
  }
}
</script>
