# frozen_string_literal: true

# Centralized SC_CURR drug mappings for mahis_core.
# These are final drug_ids (from the current Drug table) grouped
# by the SC_CURR categories used in ArtService::Reports::Pepfar::ScCurr.

module Drugs
  SC_CURR_DRUGS = {
    'TLD 30-count bottles' => [
      { drug_id: 823, name: 'TDF300/3TC300/DTG50' }
    ],
    'TLD 90-count bottles' => [
      { drug_id: 823, name: 'TDF300/3TC300/DTG50' }
    ],
    'TLD 180-count bottles' => [
      { drug_id: 823, name: 'TDF300/3TC300/DTG50' }
    ],
    'TLE/400 30-count bottles' => [
      { drug_id: 577, name: 'TDF/3TC/EFV (300/300/600mg tablet)' }
    ],
    'TLE/400 90-count bottles' => [
      { drug_id: 577, name: 'TDF/3TC/EFV (300/300/600mg tablet)' }
    ],
    'TLE 600/TEE bottles' => [
      { drug_id: 7, name: 'EFV (Efavirenz 600mg tablet)' }
    ],
    'DTG 10 90-count bottles' => [
      { drug_id: 820, name: 'Dolutegravir (10mg tablet)' }
    ],
    'DTG 50 30-count bottles' => [
      { drug_id: 822, name: 'Dolutegravir (50mg tablet)' }
    ],
    'LPV/r 100/25 tabs 60 tabs/bottle' => [
      { drug_id: 17, name: 'LPV/r (cold; Lopanavir and Ritonavir 166 mg tab)' },
      { drug_id: 66, name: 'LPV/r (Lopinavir and Ritonavir 200/50mg tablet)' },
      { drug_id: 67, name: 'LPV/r (Lopinavir and Ritonavir 100/25mg tablet)' },
      { drug_id: 581, name: 'LPV/r (Lopinavir and Ritonavir 133/33mg tablet)' },
      { drug_id: 817, name: 'Ritonavir 100mg' },
      { drug_id: 883, name: 'LPV/r Granules' }
    ],
    'LPV/r 40/10 (pediatrics) bottles' => [
      { drug_id: 87, name: 'LPV/r (Lopinavir and Ritonavir syrup)' },
      { drug_id: 819, name: 'LPV/r pellets' }
    ],
    'NVP (adult) bottles' => [
      { drug_id: 16, name: 'NVP (Nevirapine 200 mg tablet)' },
      { drug_id: 460, name: 'd4T/3TC/NVP (30/150/200mg tablet)' }
    ],
    'NVP (pediatric) bottles' => [
      { drug_id: 15, name: 'NVP (Nevirapine syrup 1.5mL/dose in 25mL bottle)' },
      { drug_id: 658, name: 'NVP (Nevirapine syrup 1mL/dose in 25mL bottle)' },
      { drug_id: 808, name: 'NVP (Nevirapine 50 mg tablet)' },
      { drug_id: 811, name: 'NVP (Nevirapine syrup 1mL/dose in 100mL bottle)' }
    ],
    'Other (adult) bottles' => [
      { drug_id: 2, name: 'Triomune-40' },
      { drug_id: 3, name: 'd4T (Stavudine 30mg tablet)' },
      { drug_id: 4, name: 'd4T (Stavudine 40mg tablet)' },
      { drug_id: 6, name: 'DDI (Didanosine 200mg tablet)' },
      { drug_id: 8, name: 'TDF (Tenofavir 300 mg tablet)' },
      { drug_id: 32, name: 'AZT (Zidovudine 300mg tablet)' },
      { drug_id: 33, name: 'AZT/3TC (Zidovudine and Lamivudine 300/150mg)' },
      { drug_id: 34, name: 'ABC (Abacavir 300mg tablet)' },
      { drug_id: 36, name: '3TC (Lamivudine 150mg tablet)' },
      { drug_id: 82, name: 'Zidolam' },
      { drug_id: 461, name: 'AZT/3TC/NVP' },
      { drug_id: 572, name: 'D4T+3TC/D4T+3TC+NVP' },
      { drug_id: 573, name: 'AZT/3TC/NVP (300/150/200mg tablet)' },
      { drug_id: 576, name: 'TDF/3TC (Tenofavir and Lamivudine 300/300mg tablet' },
      { drug_id: 580, name: 'd4T/3TC (Stavudine Lamivudine 30/150 tablet)' },
      { drug_id: 655, name: 'TDF/d4T (Tenofavir and Stavudine 300/300mg tablet' },
      { drug_id: 656, name: 'DDI/ABC/LPV/r' },
      { drug_id: 772, name: 'ATV/r (Atazanavir 300mg/Ritonavir 100mg)' },
      { drug_id: 773, name: 'TDF/3TC + ALT/r' },
      { drug_id: 774, name: 'AZT/3TC + ALT/r' },
      { drug_id: 792, name: 'ATV/(Atazanavir)' },
      { drug_id: 794, name: 'RAL (Raltegravir 400mg)' },
      { drug_id: 795, name: 'd4T/3TC/EFV (Stavudine Lamvudine Efavirenz)' },
      { drug_id: 797, name: 'Lamivudine 300' },
      { drug_id: 809, name: 'ABC/3TC (Abacavir and Lamivudine 600/300mg tablet)' },
      { drug_id: 816, name: 'Darunavir 600mg' },
      { drug_id: 818, name: 'Etravirine 100mg' },
      { drug_id: 824, name: 'AZT300/3TC300' },
      { drug_id: 1045, name: 'EFV (Efavirenz 400mg tablet)' },
      { drug_id: 1049, name: 'TDF/3TC/EFV (300/300/400mg tablet)' }
    ],
    'Other (pediatric) bottles' => [
      { drug_id: 1, name: 'Triomune-30' },
      { drug_id: 5, name: 'DDI (Didanosine 125mg tablet)' },
      { drug_id: 22, name: 'EFV (Efavirenz 100mg tablet)' },
      { drug_id: 23, name: 'EFV (Efavirenz 50mg tablet)' },
      { drug_id: 24, name: 'EFV (Efavirenz 200mg tablet)' },
      { drug_id: 25, name: 'd4T (Stavudine 20mg tablet)' },
      { drug_id: 26, name: 'd4T (Stavudine 15mg tablet)' },
      { drug_id: 30, name: 'AZT (Zidovudine syrup 10mg/mL from 100ml bottle)' },
      { drug_id: 31, name: 'AZT (Zidovudine 100mg tablet)' },
      { drug_id: 35, name: '3TC (Lamivudine syrup 10mg/mL from 100mL bottle)' },
      { drug_id: 63, name: 'LS30 (Stavudine and Lamivudine 30mg tablet)' },
      { drug_id: 64, name: 'Lamivir baby (Stavudine and Lamivudine 6/30mg tabl' },
      { drug_id: 65, name: 'Triomune baby (d4T/3TC/NVP 6/30/50mg tablet)' },
      { drug_id: 83, name: 'Coviro30 (Lamivudine + Stavudine 150/30 mg tablet)' },
      { drug_id: 84, name: 'Coviro40 (Lamivudine + Stavudine 150/40mg tablet)' },
      { drug_id: 88, name: 'd4T (Stavudine syrup)' },
      { drug_id: 97, name: 'Duovir-N' },
      { drug_id: 169, name: 'Lamivudine (5ml bottle)' },
      { drug_id: 574, name: 'AZT/3TC/NVP (60/30/50mg tablet)' },
      { drug_id: 575, name: 'ABC/3TC (Abacavir and Lamivudine 60/30mg tablet)' },
      { drug_id: 578, name: 'AZT/3TC (Zidovudine and Lamivudine 60/30 tablet)' },
      { drug_id: 579, name: 'd4T/3TC (Stavudine Lamivudine 6/30mg tablet)' },
      { drug_id: 654, name: 'Triomune junior (d4T/3TC/NVP 12/60/100mg tablet)' },
      { drug_id: 657, name: 'AZT/3TC/TDF/LPV/r' },
      { drug_id: 821, name: 'Dolutegravir (25mg tablet)' },
      { drug_id: 881, name: 'RAL (Raltegravir 25mg)' },
      { drug_id: 882, name: 'ABC/3TC (Abacavir and Lamivudine 120/60mg tablet)' },
      { drug_id: 1046, name: 'Darunavir 150mg' },
      { drug_id: 1047, name: 'Ritonavir 50mg' }
    ]
  }.freeze

  def self.sc_curr_ids_for(category_label)
    (SC_CURR_DRUGS[category_label] || []).map { |entry| entry[:drug_id] }
  end
end
