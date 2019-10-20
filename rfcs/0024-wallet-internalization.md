## Summary

---

Integrate an internationalization library into the Coda wallet for multi-language support.

## Motivation

---

The Coda wallet currently has only English text, making it more difficult for non-English speaking developers and users to easily contribute and use.

The wallet should support multiple languages to reach a wide-ranging audience.

## Detailed design

---

React-intl is currently one of the most well-supported internationalization library for React. It is built upon the native **[Internationalization API](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl)** browser API, and neatly wraps them for performance and usability enhancements.

Lib: [https://github.com/formatjs/react-intl](https://github.com/formatjs/react-intl)

Bs-bindings: [https://github.com/reasonml-community/bs-react-intl](https://github.com/reasonml-community/bs-react-intl)

General steps to implement react-intl

1. Create a JSON of IDs mapped to their text. Each new language will have their own JSON file.

Discussion: Am I converting _all_ texts in this grant? It's within capacity. Just not sure if the Coda team is comfortable with having an app-wide change immediately due to some potential internal conflicts.

```json
    // en.json

    [
      {
        "id": "page.hello",
        "defaultMessage": "Hello",
        "message": ""
      }
    ]
```

2.  Wrap the app with the react-intl provider.

```javascript
    // ReactApp.re
    let make = () => {
    let settingsValue = AddressBookProvider.createContext();
    let onboardingValue = OnboardingProvider.createContext();

        // Create the context for react-intl


        <ReactIntl.IntlProvider
        locale={/* Logic to get the right locale */}
        messages={/* Logic to get the right set of JSON messages  */}>
        	  <AddressBookProvider value=settingsValue>
        		    {...rest of the app}
        		</AddressBookProvider>
        </ReactIntl.IntlProvider>;
    };
```

3.  Replace any hardcoded English text with

```javascript
    // some react file
    <FormattedMessage id="page.hello" defaultMessage="Hello" />
```

## Drawbacks

---

Without strong support of any given language, mistranslations may occur and continual support may drop. Lack of ongoing support means the application becomes a mix of the default language (English) with translated bits.

## Rationale and alternatives

---

Besides being the most well supported library in the space, react-intl already has the bindings supported by the Reason community. Having to write the bindings ourselves adds more unnecessary complexity.

Alternatives to react-intl are listed below, although Bucklescript-bindings do not yet exist for them.

-   lingui.js - [https://github.com/lingui/js-lingui](https://github.com/lingui/js-lingui)
    -   Lingui is a 5kb framework, and offers both React and non-React APIs.
-   react i18next - [https://github.com/i18next/react-i18next](https://github.com/i18next/react-i18next)
    -   Offers a more templating style API, instead of the many stringed `ReactIntl.formattedMessage`components in react-intl.

## Prior art

---

The modern browser has a built-in Internationalization API, which inspired many of the current JS intl libraries.

## Unresolved questions

---

What percentage of the wallet should be internationalized for this scope of work?

How we do continue to support additional languages beyond English? What will be the process for adding additional translations? Who vets the accuracy?
