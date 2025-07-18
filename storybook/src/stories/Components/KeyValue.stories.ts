import type { Meta, StoryObj } from '@storybook/vue3';
import KeyValue from '@shell/components/form/KeyValue.vue';

const meta: Meta<typeof KeyValue> = { component: KeyValue };

export default meta;
type Story = StoryObj<typeof KeyValue>;

export const Default: Story = {
  render: (args: any) => ({
    components: { KeyValue },
    setup() {
      return { args };
    },
    template: '<KeyValue v-bind="args" />',
  }),
  args: {
    value: {
      foo: 'bar',
      bar: 'foo',
    },
    toggleFilter: false,
  },
};

export const Protected: Story = {
  ...Default,
  args: {
    value: {
      before:    'value',
      foo:       'bar',
      bar:       'foo',
      something: 'else'
    },
  },
};

export const ProtectedMultiline: Story = {
  ...Default,
  args: {

    value: {
      foo:   'bar',
      bar:   'foo',
      test1: `this is disabled
this is second line
this is third line`,
      test2: 'this is disabled',
      test3: 'this is disabled',
    },
    valueMultiline: true,
  },
};

export const ProtectedSuggestions: Story = {
  ...Default,
  args: {
    value: {
      foo:   'bar',
      bar:   'foo',
      test1: 'this is disabled, try to add a new one with suggestion',
    },
    keyOptions: ['test which will be disabled'],
    keyErrors:  { foo: 'Warning' }
  },
};
