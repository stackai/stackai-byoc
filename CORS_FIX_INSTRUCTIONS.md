# CORS Fix Implementation Instructions

## Problem
The CORS issue occurs because requests are going from `http://20-241-153-9.nip.io` to `http://db.20-241-153-9.nip.io`, which are different origins.

## Solution
We've updated the Supabase URL to use a proxy route: `http://20-241-153-9.nip.io/supabase`

## Required Changes to next.config.js

### 1. Update the rewrites() function
Add this rewrite rule at the beginning of your rewrites array:

```javascript
async rewrites() {
  const baseRewrites = [
    // Supabase proxy route - ADD THIS FIRST
    {
      source: '/supabase/:path*',
      destination: 'http://db.20-241-153-9.nip.io/:path*',
    },
  ];

  if (isLocalhost || isOnPremise) {
    return [
      ...baseRewrites,
      {
        source: '/',
        destination: '/auth/login',
      },
      // ... rest of your existing rewrites
    ]
  }

  return [
    ...baseRewrites,
    {
      source: '/',
      destination: framerUrl,
    },
    // ... rest of your existing rewrites
  ]
}
```

### 2. Update the headers() function
Change your existing headers function to include the supabase proxy:

```javascript
async headers() {
  return [
    {
      // Apply CORS to both API routes AND Supabase proxy
      source: '/(api|supabase)/:path*',
      headers: [
        { key: 'Access-Control-Allow-Credentials', value: 'true' },
        { key: 'Access-Control-Allow-Origin', value: '*' },
        {
          key: 'Access-Control-Allow-Methods',
          value: 'GET,OPTIONS,PATCH,DELETE,POST,PUT',
        },
        {
          key: 'Access-Control-Allow-Headers',
          value:
            'X-CSRF-Token, X-Requested-With, Accept, Accept-Version, Content-Length, Content-MD5, Content-Type, Date, X-Api-Version, Authorization, apikey, x-client-info',
        },
      ],
    },
  ]
}
```

## What This Does
1. All Supabase requests will now go to `/supabase/*` on the same domain
2. Next.js will proxy these requests to `http://db.20-241-153-9.nip.io/*`
3. The CORS headers will be applied to these proxied requests
4. No more cross-origin issues!

## Environment Variable Updated
- `NEXT_PUBLIC_SUPABASE_URL` changed from `http://db.20-241-153-9.nip.io/` to `http://20-241-153-9.nip.io/supabase`

## Next Steps
1. Update your next.config.js with the changes above
2. Rebuild and deploy your application
3. Test the authentication - CORS errors should be gone!
