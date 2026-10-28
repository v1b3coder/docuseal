<template>
  <ContextSubmenu
    class="field-settings-qes-level"
    :icon="IconWritingSign"
    :label="qesI18n.en.qes_level"
    :options="qesLevelOptions"
    :model-value="currentQesLevel"
    @select="handleSelectQesLevel"
  />
</template>

<script>
import { IconWritingSign } from '@tabler/icons-vue'
import ContextSubmenu from './field_context_submenu.vue'
import qesI18n from './qes_i18n'

export default {
  name: 'QesLevelSubmenu',
  components: { ContextSubmenu },
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
    qesLevelOptions () {
      return [
        { value: 'ades', label: qesI18n.en.qes_level_ades },
        { value: 'qes', label: qesI18n.en.qes_level_qes }
      ]
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
