// License: LGPL-3.0-or-later
const R = require('ramda')
const flatMap = require('flyd/module/flatmap')
const flyd = require('flyd')
const h = require('snabbdom/h')
flyd.mergeAll = require('flyd/module/mergeall')

const button = (text, stream) =>
  h('button.button--tiny.u-marginRight--10', {on: {click: stream}}
  , [h('i.fa.fa-plus.u-marginRight--5') , text ])

const view = state => 
  h('section.timeline-actions.u-padding--10', [
    button('Note', state.newNote$)
  , button('Email', state.clickComposing$)
  , button('Donation', [state.modalID$, 'newOffsiteDonationModal'])
  ])

module.exports = {view}
