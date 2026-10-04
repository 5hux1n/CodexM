'use strict';
const accounts = {
  work: { name: '工作账户', title: '继续网站项目', description: '查看正在处理的窗口，点击即可切换到对应任务。', detail: '网站项目 · 2 个窗口可供选择' },
  personal: { name: '个人账户', title: '整理个人工具', description: '个人账户使用独立应用数据，不必退出工作账户再登录。', detail: '个人工具 · 1 个窗口可供选择' },
  side: { name: '实验账户', title: '试试新的想法', description: '在另一个账户开展实验，正在运行的工作账户可以继续保留。', detail: '实验项目 · 1 个窗口可供选择' }
};
document.querySelectorAll('[data-account]').forEach(button => {
  button.addEventListener('click', () => {
    const account = accounts[button.dataset.account];
    document.querySelectorAll('[data-account]').forEach(other => {
      const selected = other === button;
      other.classList.toggle('active', selected);
      other.setAttribute('aria-pressed', String(selected));
    });
    document.querySelector('#window-account').textContent = account.name;
    document.querySelector('#window-title').textContent = account.title;
    document.querySelector('#window-description').textContent = account.description;
    document.querySelector('#window-detail').textContent = account.detail;
  });
});
const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
function activateTab(tab) {
  tabs.forEach(other => {
    const selected = tab === other;
    other.setAttribute('aria-selected', String(selected));
    other.tabIndex = selected ? 0 : -1;
    other.classList.toggle('active', selected);
    document.getElementById(other.getAttribute('aria-controls')).hidden = !selected;
  });
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => activateTab(tab));
  tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next === undefined) return;
    event.preventDefault();
    activateTab(tabs[next]);
    tabs[next].focus();
  });
});
