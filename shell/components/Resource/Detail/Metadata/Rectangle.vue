<script setup lang="ts">
export interface RectangleProps {
    outline?: boolean;
}

const props = withDefaults(
  defineProps<RectangleProps>(),
  { outline: false }
);

</script>

<template>
  <div
    class="rectangle"
    :class="{outline: props.outline}"
  >
    <slot />
  </div>
</template>

<style lang="scss" scoped>
.rectangle {
    border: 1px solid var(--tag-bg);
    border-radius: 4px;
    padding: 0 8px;
    height: 23px;
    line-height: 23px;

    &:not(.outline) {
        background-color: var(--tag-bg);
    }
}
</style>
