// @ts-check

const { hostDependencyCycles, render } = require('../lib/print');
const { createTree } = require('./fixtures/util');

describe('Render nix expression', () => {
  it('a single module', () => {
    const tree = hostDependencyCycles(createTree([
      { name: 'A', modules: [] },
    ]));
    expect(render({ tree })).toMatchSnapshot();
  });

  it('missing sha1', () => {
    const tree = hostDependencyCycles(createTree([
      { name: 'A', modules: [] },
    ]));
    tree[Object.keys(tree).pop()].src = {
      type: 'url',
      url: 'https://registry.yarnpkg.com/A/A.tgz',
    }
    expect(render({ tree })).toMatchSnapshot();
  });

  it('ambiguous url: no extention', () => {
    const tree = hostDependencyCycles(createTree([
      { name: 'A', modules: [] },
    ]));    
    tree[Object.keys(tree).pop()].src = {
      type: 'url',
      url: 'https://registry.yarnpkg.com/A/A',
      sha1: 'sha1',
    }
    expect(render({ tree })).toMatchSnapshot();
  });

  it('hosted modules', () => {
    const tree = hostDependencyCycles(createTree([
      { name: 'A', modules: ['B'] },
      { name: 'B', modules: ['A'] },
    ]));
    expect(render({ tree })).toMatchSnapshot();
  }); 
});
