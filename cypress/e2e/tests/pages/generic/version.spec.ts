import HomePagePo from '@/cypress/e2e/po/pages/home.po';
import ProductNavPo from '@/cypress/e2e/po/side-bars/product-side-nav.po';

// eslint-disable-next-line no-unused-vars
function interceptAndChangeVersion(version) {
  return cy.intercept('GET', '/v1/management.cattle.io.settings?exclude=metadata.managedFields', (req) => {
    req.continue((res) => {
      const serverVersion = res.body.data.find((setting) => setting.id === 'server-version');

      serverVersion.value = version;
    });
  });
}

describe('App Bar Version Number', { testIsolation: 'off', tags: ['@generic', '@adminUser', '@standardUser'] }, () => {
  const nav = new ProductNavPo();

  before(() => {
    cy.login();
  });

  // qaseId: 1199
  it('app bar shows version number (Qase ID: 1199)', () => {
    HomePagePo.goTo();

    nav.version().checkExists();
    nav.version().checkNotVisible();
  });

  // Note: Cypress will still auto-capture failure screenshots when a test fails.
  // The Qase uploader in CI attaches those (and video when enabled).

  // qaseId: 1200
  it('app bar shows short version number (Qase ID: 1200)', () => {
    interceptAndChangeVersion('v2.9.0');
    HomePagePo.goTo();

    nav.version().checkExists();
    nav.version().checkNotVisible();
    nav.version().checkVersion('v2.9');
    nav.version().checkNormalText();
  });

  it('app bar shows full version number', () => {
    interceptAndChangeVersion('v2.9.1');
    HomePagePo.goTo();

    nav.version().checkExists();
    nav.version().checkVisible();
    nav.version().checkVersion('v2.9.1');
    nav.version().checkNormalText();
  });

  it('app bar shows "About" for dev version', () => {
    interceptAndChangeVersion('12345678');
    HomePagePo.goTo();

    nav.version().checkExists();
    nav.version().checkVisible();
    nav.version().checkVersion('About');
    nav.version().checkNormalText();
  });

  it('app bar uses smaller text for longer version', () => {
    interceptAndChangeVersion('v2.10.11');
    HomePagePo.goTo();

    nav.version().checkExists();
    nav.version().checkVisible();
    nav.version().checkVersion('v2.10.11');
    nav.version().checkSmallText();
  });
});
