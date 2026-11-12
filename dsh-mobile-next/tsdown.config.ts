import { defineConfig } from 'tsdown'

export default defineConfig([
  // Host 面：Node 环境，ESM
  {
    entry: ['src/index.ts'],
    format: ['esm'],
    outDir: 'lib',
    platform: 'node',
    target: 'es2022',
    dts: true,
    // ⚠ 不要在这里 clean：两个配置是**并行**执行的，
    // host 侧的 clean 会在 client 侧写完之后把 lib/client.js 删掉
    // （实测踩过：pack 出来的 tarball 少了 client.js，插件装了但面板不出现）。
    // 清目录交给 build 脚本。
    clean: false,
    external: ['node-forge', 'qrcode'],
  },
  // Client 面：浏览器环境，CJS + __ModuleLoader__ 包装
  {
    entry: { client: 'src/client.tsx' },
    format: ['cjs'],
    outDir: 'lib',
    platform: 'browser',
    target: 'es2022',
    dts: false,
    clean: false,
    // React 由 DSH 的 loader 提供，不打包。
    //
    // ⚠ `react/jsx-runtime` 必须一起 external：漏了它，rolldown 会把
    // react 的 jsx-runtime 整个内联进来（实测 1.6 KB → 32 KB），
    // 于是插件里多出一份独立的 React 运行时，hooks 与宿主不同源。
    external: ['react', 'react/jsx-runtime'],
    outputOptions: {
      entryFileNames: 'client.js',
      // loader id 必须是包名：它把文件绑定到 manifest 的行上
      banner: 'window.__ModuleLoader__.load({ id: "dsh-mobile-next", factory: (require) => {',
      intro: 'var module = { exports: {} }; var exports = module.exports;',
      footer: 'return module.exports; } });',
    },
  },
])
