import PagePo from '@/cypress/e2e/po/pages/page.po';

describe('Legacy Index', { testIsolation: 'off', tags: ['@explorer', '@adminUser'] }, () => {
  before(() => {
    cy.login();
  });

  it('can redirect', () => {
    const page = new PagePo('/c/local/legacy');

    page.goTo();

    cy.url().should('includes', `${ Cypress.config().baseUrl }/c/local/legacy/project`);
  });
});
