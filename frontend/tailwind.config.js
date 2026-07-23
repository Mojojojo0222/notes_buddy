/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      colors: {
        surface: '#161b22',
        'surface-hover': '#1c2128',
        border: '#30363d',
        'border-light': '#21262d',
        accent: '#4ec9b0',
        'accent-muted': '#1f3a2e',
        text: '#c9d1d9',
        'text-muted': '#484f58',
        'text-bright': '#e6edf3',
        'text-link': '#79c0ff',
      },
      fontFamily: {
        mono: ['"Courier New"', 'Courier', 'monospace'],
      },
    },
  },
  plugins: [],
};
